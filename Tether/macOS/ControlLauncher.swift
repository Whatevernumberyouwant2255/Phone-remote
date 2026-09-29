import Foundation
import Observation

/// Starts DeviceKit on the connected iPhone by running the bundled
/// `enable-control.sh`, the same script as in the repository. Needs Xcode and
/// the Apple developer team the app was built with.
@MainActor
@Observable
final class ControlLauncher {
    enum State: Equatable {
        case off
        case starting
        case on
        /// DeviceKit was already started from Terminal.
        case external
        case failed(String)
    }

    private(set) var state: State = .off
    private var process: Process?
    private var output = ""

    /// Entered by the user when the app was built without a team (the
    /// downloadable DMG). Each person signs DeviceKit with their own team.
    var enteredTeamID = UserDefaults.standard.string(forKey: "teamID") ?? "" {
        didSet { UserDefaults.standard.set(enteredTeamID, forKey: "teamID") }
    }

    /// From Info.plist when built with scripts/install.sh, otherwise entered.
    private var teamID: String? {
        let built = (Bundle.main.object(forInfoDictionaryKey: "TetherTeamID") as? String) ?? ""
        let team = built.isEmpty ? enteredTeamID.trimmingCharacters(in: .whitespaces) : built
        return team.isEmpty ? nil : team
    }

    var canStart: Bool { teamID != nil }

    func start() {
        guard process == nil else { return }
        if Self.runnerAlreadyRunning() {
            state = .external
            return
        }
        guard let teamID,
              let script = Bundle.main.url(forResource: "enable-control", withExtension: "sh"),
              let patch = Bundle.main.url(forResource: "devicekit-tether", withExtension: "patch") else {
            state = .failed(String(localized: "Enter your Apple developer Team ID to turn on control."))
            return
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Phone Remote", isDirectory: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, teamID]
        var environment = ProcessInfo.processInfo.environment
        environment["DEVICEKIT_DIR"] = support.appendingPathComponent("devicekit").path
        environment["DEVICEKIT_PATCH"] = patch.path
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            Task { @MainActor in self?.consume(text) }
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { @MainActor in self?.ended(status: status) }
        }

        output = ""
        state = .starting
        do {
            try process.run()
            self.process = process
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Also stops a runner started from Terminal.
    func stop() {
        if let process {
            self.process = nil
            process.terminate()
        }
        // xcodebuild runs as a child of the script; end it too.
        Self.killRunner()
        state = .off
    }

    var isOn: Bool { state == .on || state == .external || state == .starting }

    private func consume(_ text: String) {
        output += text
        if output.contains("Server is ready") {
            state = .on
        }
    }

    private func ended(status: Int32) {
        guard process != nil else { return }
        process = nil
        let lines = output.split(separator: "\n").map(String.init)
        if let message = lines.last(where: { $0.contains("error") || $0.contains("No iPhone") }) {
            state = .failed(message.trimmingCharacters(in: .whitespaces))
        } else if state == .on {
            // Usually turned off from the iPhone app.
            state = .off
        } else {
            state = .failed(String(localized: "Control could not start. Connect and unlock the iPhone, then try again."))
        }
    }

    private static func runnerAlreadyRunning() -> Bool {
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        check.arguments = ["-f", "xcodebuild test -project devicekit-ios.xcodeproj"]
        check.standardOutput = FileHandle.nullDevice
        try? check.run()
        check.waitUntilExit()
        return check.terminationStatus == 0
    }

    private static func killRunner() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        kill.arguments = ["-f", "xcodebuild test -project devicekit-ios.xcodeproj"]
        try? kill.run()
    }
}
