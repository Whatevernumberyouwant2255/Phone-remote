import CoreGraphics
import Foundation
import OSLog

/// Optional remote control through DeviceKit, an XCTest runner that
/// developers install from Xcode (see docs/CONTROL.md). Tether never ships
/// it; it only talks to it when it is already running on this iPhone.
/// DeviceKit listens on the loopback interface only.
final class DeviceKitBridge: @unchecked Sendable {
    private let endpoint = URL(string: "http://127.0.0.1:12004/rpc")!
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 3
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()
    private let logger = Logger(subsystem: "app.phoneremote.tether", category: "DeviceKit")
    /// The last queued command. Each command waits for the previous one so a
    /// tap that focuses a field lands before the text typed into it.
    private var tail: Task<Void, Never>?

    /// True when DeviceKit answers `device.info`.
    func isAvailable() async -> Bool {
        (try? await call("device.info", [:])) != nil
    }

    /// Ends DeviceKit (and the "Automation Running" state) from the iPhone.
    /// Needs the stop command from scripts/devicekit-tether.patch.
    func stop() async -> Bool {
        (try? await call("device.stop", [:])) != nil
    }

    /// Resets the auto-lock timer with a tap outside the screen, which
    /// touches nothing. Call from the same serial queue as `perform`.
    func keepAwake() {
        enqueue("device.io.tap", ["x": -1, "y": -1])
    }

    /// Performs `control`. `portrait` is the screen size in points held
    /// upright; `quarterTurns` is how the headset rotated the picture, so
    /// touches can be turned back into portrait coordinates here and DeviceKit
    /// can skip its own slow lookups. Call from one serial queue.
    func perform(_ control: TetherControl, portrait: CGSize, quarterTurns: Int, completion: ((_ queueMs: Double, _ deviceKitMs: Double) -> Void)? = nil) {
        let method: String
        let params: [String: Any]
        func point(_ x: Double, _ y: Double) -> (Double, Double) {
            let fraction = TetherGeometry.portraitFraction(
                x: min(max(x, 0), 1), y: min(max(y, 0), 1), quarterTurns: quarterTurns
            )
            return (fraction.x * portrait.width, fraction.y * portrait.height)
        }
        // DeviceKit's long-press and gesture commands rotate points themselves,
        // so they take points in the screen as currently displayed.
        let sideways = quarterTurns % 2 != 0
        let upright = sideways ? CGSize(width: portrait.height, height: portrait.width) : portrait
        func displayed(_ x: Double, _ y: Double) -> (Double, Double) {
            (min(max(x, 0), 1) * upright.width, min(max(y, 0), 1) * upright.height)
        }
        func gesture(_ points: [(x: Double, y: Double, seconds: Double)]) -> [String: Any] {
            var actions: [[String: Any]] = []
            for (index, point) in points.enumerated() {
                let (x, y) = displayed(point.x, point.y)
                actions.append(["type": index == 0 ? "press" : "move", "x": x, "y": y, "duration": point.seconds, "button": 0])
            }
            let (x, y) = displayed(points[points.count - 1].x, points[points.count - 1].y)
            actions.append(["type": "release", "x": x, "y": y, "duration": 0, "button": 0])
            return ["actions": actions]
        }

        switch control.kind {
        case .tap:
            let (x, y) = point(control.x, control.y)
            method = "device.io.tap"
            params = ["x": x, "y": y, "portrait": true]
        case .swipe:
            let (x1, y1) = point(control.x, control.y)
            let (x2, y2) = point(control.endX, control.endY)
            method = "device.io.swipe"
            params = ["x1": Int(x1), "y1": Int(y1), "x2": Int(x2), "y2": Int(y2), "duration": min(max(control.duration, 0.05), 2)]
        case .text:
            guard let text = control.text, !text.isEmpty else { return }
            method = "device.io.text"
            params = ["text": text]
        case .longPress:
            let (x, y) = displayed(control.x, control.y)
            method = "device.io.longpress"
            params = ["x": x, "y": y, "duration": min(max(control.duration, 0.5), 2)]
        case .button:
            switch control.button {
            case .appSwitcher:
                // Slide up from the bottom edge and pause.
                method = "device.io.gesture"
                params = gesture([(0.5, 0.995, 0.05), (0.5, 0.80, 0.12), (0.5, 0.62, 0.18), (0.5, 0.61, 0.45)])
            case .spotlight:
                // Pull down from the middle of the Home Screen.
                method = "device.io.gesture"
                params = gesture([(0.5, 0.35, 0.05), (0.5, 0.50, 0.12), (0.5, 0.62, 0.12)])
            case .some(let button):
                method = "device.io.button"
                params = ["button": button.rawValue]
            case .none:
                return
            }
        }

        enqueue(method, params, completion: completion)
    }

    private func enqueue(_ method: String, _ params: [String: Any], completion: ((Double, Double) -> Void)? = nil) {
        let previous = tail
        let enqueued = ProcessInfo.processInfo.systemUptime
        tail = Task {
            await previous?.value
            let started = ProcessInfo.processInfo.systemUptime
            do {
                _ = try await call(method, params)
            } catch {
                logger.error("\(method, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            let finished = ProcessInfo.processInfo.systemUptime
            completion?((started - enqueued) * 1000, (finished - started) * 1000)
        }
    }

    private func call(_ method: String, _ params: [String: Any]) async throws -> Any {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0", "method": method, "params": params, "id": 1,
        ])
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil, let result = object["result"] else {
            throw URLError(.badServerResponse)
        }
        return result
    }
}
