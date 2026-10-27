// Exercise notification behavior without requesting permission or posting to the system notification center.
import AppKit
import UserNotifications

private let testError = NSError(domain: "NotificationTests", code: 7)

private final class NotificationFixture {
    var statuses: [UNAuthorizationStatus] = [.authorized]
    var settingsError = false
    var authorizationError = false
    var postingError = false
    var settingsReads = 0
    var authorizationRequests = 0
    var requests: [UNNotificationRequest] = []

    func run(_ arguments: [String]) -> Int32 {
        notifyUpdate(["NightKeys"] + arguments, status: {
            self.settingsReads += 1
            if self.settingsError { throw testError }
            return self.statuses.removeFirst()
        }, authorize: {
            self.authorizationRequests += 1
            if self.authorizationError { throw testError }
        }, post: { request in
            self.requests.append(request)
            if self.postingError { throw testError }
        })
    }
}

// Keep preference tests in memory so they never alter the installed app's domain.
private final class LevelDefaults: UserDefaults {
    var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func synchronize() -> Bool { true }
}

private func testLevel() {
    for legacy: Double? in [nil, 0, 0.01, -1, 0.75, 2] {
        let defaults = LevelDefaults()
        defaults.values[legacyBrightnessKey] = legacy
        let expected = (legacy ?? 0) > 0.01 ? min(legacy!, 1) : 0.5
        precondition(readLevel(from: defaults) == expected)
        precondition(defaults.values[levelKey] as? Double == expected)
        defaults.values[legacyBrightnessKey] = 0.2
        precondition(readLevel(from: defaults) == expected)
    }
    for level in [0.0, 0.005, 0.25, 1, -1, 2] {
        let defaults = LevelDefaults()
        defaults.values[levelKey] = level
        defaults.values[legacyBrightnessKey] = 0.9
        precondition(readLevel(from: defaults) == min(max(level, 0), 1))
    }
    let defaults = LevelDefaults()
    defaults.values[levelKey] = 0.625
    var previews: [Float] = []
    var notifications = 0
    let model = Model(defaults: defaults, startObserving: false, previewBrightness: { previews.append($0) },
                      settingsChanged: { notifications += 1 })
    precondition(model.brightness == 0.625)
    model.readSystemSettings()
    precondition(model.brightness == 0.625)
    defaults.values[levelKey] = 0.75
    model.readAgentState()
    precondition(model.brightness == 0.75 && previews.isEmpty && notifications == 0)
    for level in [0.25, 0, 1, -1, 2] {
        model.setBrightness(level)
        let expected = min(max(level, 0), 1)
        precondition(model.brightness == expected && defaults.values[levelKey] as? Double == expected)
        precondition(previews.last == Float(expected))
    }
    model.setBrightness(0.5)
    model.setBrightness(model.brightness - brightnessStep)
    model.setBrightness(model.brightness + brightnessStep)
    precondition(model.brightness == 0.5 && notifications == previews.count && notifications == 8)
    print("Passed window level checks: migration, fixed slider, persistence, notification, preview and steps.")
}

@main
enum NotificationTests {
    @MainActor
    static func main() throws {
        precondition(NSApp == nil)
        testLevel()
        let installed = ["--notify-update", "1.2.3", "--installed"]
        let available = ["--notify-update", "1.2.3", "--available"]
        for version in ["", "v1.2.3", "1..2", ".1", "1.", "1.2.3.4", "-1", "1-beta", "1/2", "1. 2", "\u{0661}"] {
            let fixture = NotificationFixture()
            precondition(fixture.run(["--notify-update", version, "--installed"]) == 2)
            precondition(fixture.settingsReads == 0 && fixture.authorizationRequests == 0 && fixture.requests.isEmpty)
        }
        for arguments in [[], ["--notify-update"], ["--notify-update", "1"],
                          ["--notify-update", "1", "--other"], installed + ["extra"],
                          installed + ["--available"], ["--available", "1", "--notify-update"]] {
            let fixture = NotificationFixture()
            precondition(fixture.run(arguments) == 2 && fixture.settingsReads == 0)
        }
        for version in ["1", "1.2", "1.2.3", "01.002.0003", "99999999999999999999999999999999"] {
            let fixture = NotificationFixture()
            precondition(fixture.run(["--notify-update", version, "--installed"]) == 0)
            precondition(fixture.requests.count == 1 && fixture.authorizationRequests == 0)
        }
        for status in [UNAuthorizationStatus.authorized, .provisional] {
            for arguments in [installed, available] {
                let fixture = NotificationFixture()
                fixture.statuses = [status]
                precondition(fixture.run(arguments) == 0 && fixture.authorizationRequests == 0)
                let request = fixture.requests[0]
                let isInstalled = arguments == installed
                precondition(request.identifier == "release-update" && request.trigger == nil)
                precondition(request.content.title == (isInstalled ? "NightKeys updated to 1.2.3"
                    : "NightKeys 1.2.3 is available"))
                precondition(request.content.body == (isInstalled ? "The update was installed successfully."
                    : "Open settings to install the update."))
            }
        }
        for finalStatus in [UNAuthorizationStatus.authorized, .provisional, .denied, .notDetermined] {
            let fixture = NotificationFixture()
            fixture.statuses = [.notDetermined, finalStatus]
            precondition(fixture.run(installed) == 0)
            precondition(fixture.authorizationRequests == 1 && fixture.settingsReads == 2)
            precondition(fixture.requests.count == ([.authorized, .provisional].contains(finalStatus) ? 1 : 0))
        }
        let denied = NotificationFixture()
        denied.statuses = [.denied]
        precondition(denied.run(available) == 0 && denied.authorizationRequests == 0 && denied.requests.isEmpty)
        let settingsFailure = NotificationFixture()
        settingsFailure.settingsError = true
        precondition(settingsFailure.run(installed) == 1 && settingsFailure.requests.isEmpty)
        let authorizationFailure = NotificationFixture()
        authorizationFailure.statuses = [.notDetermined]
        authorizationFailure.authorizationError = true
        precondition(authorizationFailure.run(installed) == 1 && authorizationFailure.requests.isEmpty)
        let postingFailure = NotificationFixture()
        postingFailure.postingError = true
        precondition(postingFailure.run(installed) == 1)

        let reply = NotificationReply<Int>()
        DispatchQueue.global().async { reply.complete(.success(42)) }
        let value = try reply.wait("Test callback", deadline: .now() + 2)
        precondition(value == 42)
        let timeout = NotificationReply<Void>()
        do {
            try timeout.wait("Test callback", deadline: .now())
            preconditionFailure("Expected a bounded timeout")
        } catch {
            precondition((error as NSError).domain == "NightKeys.NotificationTimeout")
        }
        // A callback that arrives after the wait timed out still owns a valid reply.
        timeout.complete(.success(()))
        precondition(NSApp == nil)
        print("Passed notification checks: arguments, permission states, content, errors, "
            + "bounded callbacks and no NSApplication.")
    }
}
