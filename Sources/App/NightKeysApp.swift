// NightKeys.app: settings window for the nightkeysd background agent.
// Runs only while the window is open; the agent does the actual work.
// Timeout and low-light mode use the macOS settings (System Settings > Keyboard).
// The window owns the level used for each typing session.
import ServiceManagement
import SwiftUI
import UserNotifications
import os.log

private let updateLog = OSLog(subsystem: "io.github.fratayaydn.nightkeys", category: "updater")

// Each callback owns its reply until completion, including after a timeout. The semaphore publishes the result.
final class NotificationReply<Value>: @unchecked Sendable {
    private let done = DispatchSemaphore(value: 0)
    private var result: Result<Value, Error>?

    func complete(_ result: Result<Value, Error>) {
        self.result = result
        done.signal()
    }

    func wait(_ step: String, deadline: DispatchTime = .now() + 30) throws -> Value {
        guard done.wait(timeout: deadline) == .success, let result else {
            os_log("%{public}@ timed out", log: updateLog, type: .error, step)
            throw NSError(domain: "NightKeys.NotificationTimeout", code: 1)
        }
        return try result.get()
    }
}

private func notificationStatus(_ center: UNUserNotificationCenter) throws -> UNAuthorizationStatus {
    let reply = NotificationReply<UNAuthorizationStatus>()
    center.getNotificationSettings { reply.complete(.success($0.authorizationStatus)) }
    return try reply.wait("Notification settings")
}

private func authorizeUpdateNotifications() throws {
    let reply = NotificationReply<Bool>()
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
        if let error { reply.complete(.failure(error)) }
        else { reply.complete(.success(granted)) }
    }
    _ = try reply.wait("Notification authorization")
}

private func postUpdateNotification(_ request: UNNotificationRequest) throws {
    let reply = NotificationReply<Void>()
    UNUserNotificationCenter.current().add(request) { error in
        if let error { reply.complete(.failure(error)) }
        else { reply.complete(.success(())) }
    }
    try reply.wait("Post notification")
}

func notifyUpdate(
    _ arguments: [String],
    status: () throws -> UNAuthorizationStatus = { try notificationStatus(.current()) },
    authorize: () throws -> Void = authorizeUpdateNotifications,
    post: (UNNotificationRequest) throws -> Void = postUpdateNotification
) -> Int32 {
    guard arguments.count == 4, arguments[1] == "--notify-update",
          arguments[3] == "--installed" || arguments[3] == "--available" else { return 2 }
    let version = arguments[2]
    let parts = version.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count), parts.allSatisfy({ part in
        !part.isEmpty && part.utf8.allSatisfy { (48...57).contains($0) }
    }) else { return 2 }

    do {
        var authorization = try status()
        if authorization == .notDetermined {
            try authorize()
            authorization = try status()
        }
        guard authorization == .authorized || authorization == .provisional else {
            os_log("Notifications are not allowed", log: updateLog, type: .info)
            return 0
        }
        let installed = arguments[3] == "--installed"
        let content = UNMutableNotificationContent()
        content.title = installed ? "NightKeys updated to \(version)"
            : "NightKeys \(version) is available"
        content.body = installed ? "The update was installed successfully." : "Open settings to install the update."
        let request = UNNotificationRequest(identifier: "release-update", content: content, trigger: nil)
        try post(request)
        os_log("Release notification posted", log: updateLog, type: .info)
        return 0
    } catch {
        let error = error as NSError
        os_log("Release notification failed: %{public}@ %ld", log: updateLog, type: .error, error.domain, error.code)
        return 1
    }
}


let prefsDomain = "io.github.fratayaydn.nightkeys"
let agentPlistName = "io.github.fratayaydn.nightkeys.agent.plist"
let updaterPlistName = "io.github.fratayaydn.nightkeys.updater.plist"
let updaterJob = "gui/\(getuid())/io.github.fratayaydn.nightkeys.updater"
let settingsChangedNotification = Notification.Name("io.github.fratayaydn.nightkeys.SettingsChanged")
let statusChangedNotification = Notification.Name("io.github.fratayaydn.nightkeys.StatusChanged")
let verifyPermissionNotification = Notification.Name("io.github.fratayaydn.nightkeys.VerifyPermission")
let thresholdKey = "AmbientThresholdLux"
let permissionKey = "StatusInputMonitoringGranted"
let defaultThresholdLux = 3.0
let registeredBuildKey = "RegisteredBuildID"
let currentBuildID = Bundle.main.object(forInfoDictionaryKey: "NTBuildID") as? String ?? ""

/// The brightness keys change keyboard brightness by 1/16; the buttons at the ends of the slider do the same.
let brightnessStep = 1.0 / 16
let levelKey = "Level"
let legacyBrightnessKey = "StatusUserBrightness"  // read-only migration source

func readLevel(from defaults: UserDefaults) -> Double {
    if let level = defaults.object(forKey: levelKey) as? Double { return min(max(level, 0), 1) }
    let legacy = defaults.double(forKey: legacyBrightnessKey)
    let level = legacy > 0.01 ? min(legacy, 1) : 0.5
    defaults.set(level, forKey: levelKey)
    defaults.synchronize()
    return level
}

/// The same choices System Settings offers; 0 means never.
let timeoutChoices: [(seconds: Double, label: String)] = [
    (5, "5 seconds"), (10, "10 seconds"), (30, "30 seconds"), (60, "1 minute"), (300, "5 minutes"), (0, "Never"),
]

final class Model: ObservableObject {
    @Published var idleDimTime = 10.0
    @Published var lowLightMode = true
    @Published var brightness = 0.5
    @Published var thresholdLux = defaultThresholdLux
    @Published var ambientLux = -1.0
    @Published var agentStatus = SMAppService.Status.notRegistered
    @Published var permissionGranted: Bool?
    @Published var errorMessage: String?

    @Published var automaticUpdates = true
    @Published var checkingUpdates = false
    @Published var latestVersion: String?
    @Published var lastUpdateCheck: Date?
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"

    let hasKeyboard: Bool
    // The app's bundle identifier is prefsDomain, so its standard defaults are the domain the agent reads.
    private let defaults: UserDefaults
    private let previewBrightness: (Float) -> Void
    private let settingsChanged: () -> Void
    private let agent = SMAppService.agent(plistName: agentPlistName)
    private var luxTimer: Timer?

    init(defaults: UserDefaults = .standard, startObserving: Bool = true,
         previewBrightness: @escaping (Float) -> Void = NTSetBrightness,
         settingsChanged: @escaping () -> Void = {
             DistributedNotificationCenter.default().postNotificationName(
                 settingsChangedNotification, object: nil, deliverImmediately: true)
         }) {
        self.defaults = defaults
        self.previewBrightness = previewBrightness
        self.settingsChanged = settingsChanged
        hasKeyboard = startObserving && NTHasBacklitKeyboard()
        brightness = readLevel(from: defaults)
        guard startObserving else { return }
        reregisterAfterUpdate()
        readSystemSettings()
        readAgentState()
        readUpdateState()
        let stored = defaults.double(forKey: thresholdKey)
        thresholdLux = stored > 0 ? stored : defaultThresholdLux
        NTObserveSystemSettings { [weak self] in self?.readSystemSettings() }
        DistributedNotificationCenter.default().addObserver(forName: statusChangedNotification, object: nil, queue: .main) {
            [weak self] _ in self?.readAgentState()
        }
        // The agent cannot notice permission changes on its own; ask it to check once per launch.
        checkPermissionAgain()
        // The light sensor has no change notification; sample it only while this window is open.
        luxTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.ambientLux = NTAmbientLux()
        }
        ambientLux = NTAmbientLux()
    }

    func readSystemSettings() {
        idleDimTime = NTIdleDimTime()
        lowLightMode = NTAutoBrightness()
    }

    func readAgentState() {
        agentStatus = agent.status
        defaults.synchronize()
        permissionGranted = defaults.object(forKey: permissionKey) as? Bool
        brightness = readLevel(from: defaults)
    }

    /// launchd only starts the agent build that was registered (its code signature is part of the launch
    /// constraint), so after an update the agent is registered again, if it was enabled. The new registration
    /// must wait until the old one is fully removed.
    private func reregisterAfterUpdate() {
        guard defaults.string(forKey: registeredBuildKey) != currentBuildID
            || SMAppService.agent(plistName: updaterPlistName).status == .notRegistered else { return }
        defaults.set(currentBuildID, forKey: registeredBuildKey)
        guard agent.status == .enabled || agent.status == .requiresApproval else { return }
        DispatchQueue.global().async { [weak self] in
            reregisterAgent()
            if !agentIsRunning() { reregisterAgent() }  // right after an update the first pass may not take
            DispatchQueue.main.async { self?.readAgentState() }
        }
    }

    func readUpdateState() {
        defaults.synchronize()
        automaticUpdates = defaults.object(forKey: "AutomaticallyInstallUpdates") == nil
            || defaults.bool(forKey: "AutomaticallyInstallUpdates")
        latestVersion = defaults.string(forKey: "LatestVersion")
        lastUpdateCheck = defaults.object(forKey: "LastUpdateCheck") as? Date
    }

    var availableVersion: String? {
        guard let latestVersion else { return nil }
        let latest = latestVersion.split(separator: ".").map(String.init)
        let current = version.split(separator: ".").map(String.init)
        for index in 0..<3 {
            let a = index < latest.count ? latest[index] : "0"
            let b = index < current.count ? current[index] : "0"
            let comparison = a.compare(b, options: .numeric)
            if comparison != .orderedSame { return comparison == .orderedDescending ? latestVersion : nil }
        }
        return nil
    }

    var lastCheckedText: String {
        guard let lastUpdateCheck else { return "Last checked: never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: lastUpdateCheck, relativeTo: Date()))"
    }

    func setAutomaticUpdates(_ on: Bool) {
        defaults.set(on, forKey: "AutomaticallyInstallUpdates")
        defaults.synchronize()
        automaticUpdates = on
    }

    func checkUpdates(install: Bool = false) {
        guard !checkingUpdates else { return }
        checkingUpdates = true
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/nightkeysd")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--update-check", "--force"] + (install ? ["--install"] : [])
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var message: String?
            do {
                try process.run()
                process.waitUntilExit()
                if process.terminationReason != .exit || process.terminationStatus != 0 {
                    message = "Could not complete the update. Try again later."
                }
            } catch {
                message = "Could not check for updates: \(error.localizedDescription)"
            }
            let result = message
            DispatchQueue.main.async {
                self?.checkingUpdates = false
                self?.errorMessage = result
                self?.readUpdateState()
            }
        }
    }

    func checkPermissionAgain() {
        DistributedNotificationCenter.default().postNotificationName(verifyPermissionNotification, object: nil, deliverImmediately: true)
    }

    func setIdleDimTime(_ seconds: Double) { idleDimTime = seconds; NTSetIdleDimTime(seconds) }
    func setLowLightMode(_ on: Bool) { lowLightMode = on; NTSetAutoBrightness(on) }
    func setBrightness(_ level: Double) {
        let level = min(max(level, 0), 1)
        brightness = level
        defaults.set(level, forKey: levelKey)
        defaults.synchronize()
        settingsChanged()
        previewBrightness(Float(level))
    }

    func setThreshold(_ lux: Double) {
        thresholdLux = lux
        defaults.set(lux, forKey: thresholdKey)
        defaults.synchronize()
        settingsChanged()
    }

    var isEnabled: Bool { agentStatus == .enabled || agentStatus == .requiresApproval }

    func setAgentEnabled(_ on: Bool) {
        do {
            try setLoginItemsEnabled(on)
        } catch {
            NSLog("NightKeys: could not \(on ? "register" : "unregister") the agent: \(error)")
        }
        // The agent gives control back when it stops, but it may not have been running (e.g. still waiting for
        // permission), so make sure here: macOS's idle timer runs again and the light is at the user's level.
        if !on {
            let level = brightness > 0 ? brightness : 0.5
            NTGiveControlToMacOS(Float(level))
        }
        readAgentState()
    }
}

/// Lux values span orders of magnitude, so the threshold slider is logarithmic.
let luxRange = log10(0.3)...log10(300.0)

struct ContentView: View {
    @StateObject private var model = Model()

    var body: some View {
        Form {
            if !model.hasKeyboard {
                StatusRow(symbol: "info.circle.fill", color: .blue, title: "No Backlit Keyboard",
                          detail: "This Mac has no built-in backlit keyboard, so NightKeys has nothing to control.")
            }

            Section {
                // Two texts in a Form row label: macOS shows the second one as the row's grey description.
                Toggle(isOn: Binding(get: { model.isEnabled }, set: { model.setAgentEnabled($0) })) {
                    Text("Enable NightKeys")
                    Text("Lights the keyboard only when you type on the built-in keyboard. The trackpad, mice and external keyboards are ignored.")
                }
                statusRow
            }

            Group {
            Section("Light") {
                Picker("Turn off after", selection: Binding(get: { model.idleDimTime }, set: { model.setIdleDimTime($0) })) {
                    ForEach(timeoutChoices, id: \.seconds) { Text($0.label).tag($0.seconds) }
                    if !timeoutChoices.contains(where: { $0.seconds == model.idleDimTime }) {
                        Text("\(Int(model.idleDimTime)) seconds").tag(model.idleDimTime)
                    }
                }
                LabeledContent("Brightness") {
                    // Like the slider in System Settings: continuous, 0 turns the light off, and the symbols at the
                    // ends step by 1/16 like the brightness keys.
                    Slider(value: Binding(get: { model.brightness }, set: { model.setBrightness($0) }), in: 0...1) {
                        Text("Brightness")
                    } minimumValueLabel: {
                        Button { model.setBrightness(model.brightness - brightnessStep) } label: {
                            Image(systemName: "light.min").font(.system(size: 16))
                        }
                            .buttonStyle(.borderless)
                            .help("Dimmer")
                    } maximumValueLabel: {
                        Button { model.setBrightness(model.brightness + brightnessStep) } label: {
                            Image(systemName: "light.max").font(.system(size: 16))
                        }
                            .buttonStyle(.borderless)
                            .help("Brighter")
                    }
                    .labelsHidden()
                }
            }

            Section {
                Toggle(isOn: Binding(get: { model.lowLightMode }, set: { model.setLowLightMode($0) })) {
                    Text("Stay off in bright rooms")
                    Text("The same setting as \u{201C}Adjust keyboard brightness in low light\u{201D} in System Settings > Keyboard, with a threshold you choose.")
                }
                if model.lowLightMode {
                    LabeledContent {
                        HStack {
                            Slider(value: Binding(get: { log10(max(model.thresholdLux, 0.3)) },
                                                  set: { model.setThreshold((pow(10, $0) * 10).rounded() / 10) }),
                                   in: luxRange)
                            Text(String(format: "%.1f lux", model.thresholdLux)).monospacedDigit().frame(width: 70, alignment: .trailing)
                        }
                    } label: {
                        Text("Bright above")
                        Text("The sensor reads low; set this with the lid at its usual angle.")
                    }
                    LabeledContent("Light here now") {
                        HStack {
                            Text(model.ambientLux < 0 ? "No sensor" : String(format: "%.1f lux", model.ambientLux)).monospacedDigit()
                            Button("Use as limit") { model.setThreshold((model.ambientLux * 10).rounded() / 10) }
                                .disabled(model.ambientLux < 0)
                        }
                    }
                }
            } header: {
                Text("Ambient Light")
            }
            }
            // Off means macOS has full control: these settings belong to NightKeys mode only.
            .disabled(!model.isEnabled)
            .opacity(model.isEnabled ? 1 : 0.45)

            Section("Updates") {
                Toggle(isOn: Binding(get: { model.automaticUpdates }, set: { model.setAutomaticUpdates($0) })) {
                    Text("Install updates automatically")
                    Text("Only updates signed by the developer and notarized by Apple.")
                }
                HStack {
                    Text("Version \(model.version), \(model.lastCheckedText.lowercased().replacingOccurrences(of: "checked:", with: "checked"))")
                        .lineLimit(1)
                    Spacer()
                    Button(model.checkingUpdates ? "Checking..." : "Check Now") { model.checkUpdates() }
                        .disabled(model.checkingUpdates)
                }
                if !model.automaticUpdates, let version = model.availableVersion {
                    Button("Install \(version)") { model.checkUpdates(install: true) }
                        .disabled(model.checkingUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
        .alert("NightKeys", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    @ViewBuilder private var statusRow: some View {
        switch model.agentStatus {
        case .enabled where model.permissionGranted == false:
            StatusRow(symbol: "exclamationmark.triangle.fill", color: .yellow,
                      title: "Input Monitoring Required",
                      detail: "NightKeys needs this to notice when you type on the built-in keyboard. It never records or reads what you type. After you allow it, come back here and click Check Again.\n\nAlready on in the list? After an update macOS treats NightKeys as a new app: remove it with \u{2212} and allow it again.",
                      action: ("Open Privacy & Security\u{2026}", {
                          NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                      }),
                      secondaryAction: ("Check Again", { model.checkPermissionAgain() }))
        case .enabled where model.permissionGranted == nil:
            StatusRow(symbol: "clock.fill", color: .secondary, title: "Starting\u{2026}", detail: "NightKeys is starting in the background.")
        case .enabled:
            StatusRow(symbol: "checkmark.circle.fill", color: .green, title: "NightKeys Is On",
                      detail: model.idleDimTime > 0
                          ? "The keyboard lights up when you type and turns off \(timeoutPhrase(model.idleDimTime)) after the last key."
                          : "The keyboard lights up when you type and stays on.")
        case .requiresApproval:
            StatusRow(symbol: "exclamationmark.triangle.fill", color: .yellow,
                      title: "Approval Required",
                      detail: "Allow NightKeys under \u{201C}Allow in the Background\u{201D} so it can run without this window.",
                      action: ("Open Login Items\u{2026}", { SMAppService.openSystemSettingsLoginItems() }))
        default:
            StatusRow(symbol: "circle", color: .secondary, title: "NightKeys Is Off",
                      detail: "macOS controls the keyboard backlight as usual.")
        }
    }
}

func timeoutPhrase(_ seconds: Double) -> String {
    let label = timeoutChoices.first { $0.seconds == seconds }?.label ?? "\(Int(seconds)) seconds"
    return label
}

/// A status line in the style of System Settings: symbol, title, explanation and an optional button.
struct StatusRow: View {
    let symbol: String
    let color: Color
    let title: String
    let detail: String
    var action: (label: String, run: () -> Void)? = nil
    var secondaryAction: (label: String, run: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if action != nil || secondaryAction != nil {
                    HStack {
                        if let action { Button(action.label, action: action.run) }
                        if let secondaryAction { Button(secondaryAction.label, action: secondaryAction.run) }
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

let agentJob = "gui/\(getuid())/io.github.fratayaydn.nightkeys.agent"

// Remove the updater first, since removing the main job can terminate the background process.
func setLoginItemsEnabled(_ enabled: Bool) throws {
    let names = enabled ? [agentPlistName, updaterPlistName] : [updaterPlistName, agentPlistName]
    var firstError: Error?
    for name in names {
        let service = SMAppService.agent(plistName: name)
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            if firstError == nil { firstError = error }
        }
    }
    if let firstError { throw firstError }
}

@discardableResult
func launchctl(_ arguments: [String]) -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = Pipe()
    try? process.run()
    process.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

/// Starts the agent once through launchd. After an update this makes launchd pin the agent to the new build;
/// without it the job can stay stuck with "needs LWCR update" (see scripts/install.sh).
func startAgentOnce() { launchctl(["kickstart", agentJob]) }

func agentIsRunning() -> Bool { launchctl(["print", agentJob]).contains("state = running") }

/// Unregister, wait until launchd has dropped the job, register and start once: the sequence that refreshes
/// the agent's launch constraint after an update (see scripts/install.sh).
func reregisterAgent() {
    try? setLoginItemsEnabled(false)
    for job in [updaterJob, agentJob] {
        for _ in 0..<70 where !launchctl(["print", job]).isEmpty { Thread.sleep(forTimeInterval: 0.5) }
    }
    Thread.sleep(forTimeInterval: 1)
    try? setLoginItemsEnabled(true)
    startAgentOnce()
    Thread.sleep(forTimeInterval: 2)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // `NightKeys --unregister` / `--register` (used by the Makefile): change the login item and quit.
        if CommandLine.arguments.contains("--unregister") {
            try? setLoginItemsEnabled(false)
            exit(0)
        }
        if CommandLine.arguments.contains("--register") {
            do {
                try setLoginItemsEnabled(true)
                startAgentOnce()
                // This build is registered now; the window must not re-register it again (see reregisterAfterUpdate).
                UserDefaults.standard.set(currentBuildID, forKey: registeredBuildKey)
                UserDefaults.standard.synchronize()  // exit() would otherwise drop the unsaved value
                exit(0)
            } catch {
                FileHandle.standardError.write("NightKeys: could not register the background agent: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

#if !NOTIFICATION_TESTS
@main
#endif
enum NightKeysMain {
    @MainActor
    static func main() {
        // Inspect notification arguments before creating NSApplication, a delegate or any SwiftUI state.
        if CommandLine.arguments.contains("--notify-update") {
            exit(notifyUpdate(CommandLine.arguments))
        }
        NightKeysApp.main()
    }
}

struct NightKeysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("NightKeys", id: "main") { ContentView() }
            .windowResizability(.contentSize)
    }
}
