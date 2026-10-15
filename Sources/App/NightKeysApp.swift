// NightKeys.app: settings window for the nightkeysd background agent.
// Runs only while the window is open; the agent does the actual work.
// Timeout, low-light mode and brightness are the macOS settings themselves (System Settings > Keyboard),
// so changes made here or there show up in both places.
import ServiceManagement
import SwiftUI

let prefsDomain = "io.github.fratayaydn.nightkeys"
let agentPlistName = "io.github.fratayaydn.nightkeys.agent.plist"
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
let userBrightnessKey = "StatusUserBrightness"  // the level the user picked, published by the agent

/// The same choices System Settings offers; 0 means never.
let timeoutChoices: [(seconds: Double, label: String)] = [
    (5, "5 seconds"), (10, "10 seconds"), (30, "30 seconds"), (60, "1 minute"), (300, "5 minutes"), (0, "Never"),
]

final class Model: ObservableObject {
    @Published var idleDimTime = 10.0
    @Published var lowLightMode = true
    @Published var brightness = 0.5
    private var brightnessSetAt = Date.distantPast  // to ignore the echo of our own brightness changes
    @Published var thresholdLux = defaultThresholdLux
    @Published var ambientLux = -1.0
    @Published var agentStatus = SMAppService.Status.notRegistered
    @Published var permissionGranted: Bool?

    let hasKeyboard = NTHasBacklitKeyboard()
    // The app's bundle identifier is prefsDomain, so its standard defaults are the domain the agent reads.
    private let defaults = UserDefaults.standard
    private let agent = SMAppService.agent(plistName: agentPlistName)
    private var luxTimer: Timer?

    init() {
        reregisterAfterUpdate()
        readSystemSettings()
        readAgentState()
        if let level = defaults.object(forKey: userBrightnessKey) as? Double { brightness = level }
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
        // Our own change comes back as a notification, first with in-between values of the fade: ignore it briefly.
        let level = Double(NTBrightness())
        let ownChangeEcho = Date().timeIntervalSince(brightnessSetAt) < 1
        if level > 0.01 && !ownChangeEcho { brightness = level }  // 0: the light is just off
    }

    func readAgentState() {
        agentStatus = agent.status
        defaults.synchronize()
        permissionGranted = defaults.object(forKey: permissionKey) as? Bool
    }

    /// launchd only starts the agent build that was registered (its code signature is part of the launch
    /// constraint), so after an update the agent is registered again, if it was enabled. The new registration
    /// must wait until the old one is fully removed.
    private func reregisterAfterUpdate() {
        guard defaults.string(forKey: registeredBuildKey) != currentBuildID else { return }
        defaults.set(currentBuildID, forKey: registeredBuildKey)
        guard agent.status == .enabled else { return }
        DispatchQueue.global().async { [weak self] in
            reregisterAgent()
            if !agentIsRunning() { reregisterAgent() }  // right after an update the first pass may not take
            DispatchQueue.main.async { self?.readAgentState() }
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
        brightnessSetAt = Date()
        NTSetBrightness(Float(level))
    }

    func setThreshold(_ lux: Double) {
        thresholdLux = lux
        defaults.set(lux, forKey: thresholdKey)
        defaults.synchronize()
        DistributedNotificationCenter.default().postNotificationName(settingsChangedNotification, object: nil, deliverImmediately: true)
    }

    var isEnabled: Bool { agentStatus == .enabled || agentStatus == .requiresApproval }

    func setAgentEnabled(_ on: Bool) {
        do {
            if on { try agent.register() } else { try agent.unregister() }
        } catch {
            NSLog("NightKeys: could not \(on ? "register" : "unregister") the agent: \(error)")
        }
        // The agent gives control back when it stops, but it may not have been running (e.g. still waiting for
        // permission), so make sure here: macOS's idle timer runs again and the light is at the user's level.
        if !on {
            let level = brightness > 0.01 ? brightness : 0.5
            brightness = level
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
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize()
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
    let agent = SMAppService.agent(plistName: agentPlistName)
    try? agent.unregister()
    for _ in 0..<70 where !launchctl(["print", agentJob]).isEmpty { Thread.sleep(forTimeInterval: 0.5) }
    Thread.sleep(forTimeInterval: 1)
    try? agent.register()
    startAgentOnce()
    Thread.sleep(forTimeInterval: 2)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // `NightKeys --unregister` / `--register` (used by the Makefile): change the login item and quit.
        if CommandLine.arguments.contains("--unregister") {
            try? SMAppService.agent(plistName: agentPlistName).unregister()
            exit(0)
        }
        if CommandLine.arguments.contains("--register") {
            do {
                try SMAppService.agent(plistName: agentPlistName).register()
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

@main
struct NightKeysApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("NightKeys", id: "main") { ContentView() }
            .windowResizability(.contentSize)
    }
}
