import CoreGraphics
import ImageIO
import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

@MainActor
@Observable
final class ViewerModel {
    enum Phase: Equatable {
        case waiting
        case connecting(deviceName: String)
        case mirroring(deviceName: String)
        /// The stream dropped; the last picture stays up while the iPhone reconnects.
        case reconnecting(deviceName: String)
    }

    enum WindowSize: String, CaseIterable, Identifiable {
        case small, medium, large
        var id: String { rawValue }

        /// Length of the phone's long edge, in points.
        var longEdge: CGFloat {
            #if os(macOS)
            // Relative to the screen, keeping room for Home and the padding,
            // so even Large fits on a small laptop display.
            let available = max((NSScreen.main?.visibleFrame.height ?? 900) - 96, 400)
            switch self {
            case .small: return available * 0.62
            case .medium: return available * 0.80
            case .large: return available
            }
            #else
            switch self {
            case .small: return 640
            case .medium: return 820
            case .large: return 1040
            }
            #endif
        }

        var larger: WindowSize { self == .small ? .medium : .large }
        var smaller: WindowSize { self == .large ? .medium : .small }
    }

    private(set) var phase: Phase = .waiting
    private(set) var headsetName = ReceiverKind.current.genericName
    private(set) var code: String
    private(set) var listenerError: String?
    private(set) var recentlyPairedDevice: String?
    /// Encoded video size before rotation.
    private(set) var videoSize = CGSize(width: 1320, height: 2868)
    /// Quarter turns clockwise needed to display the picture upright.
    private(set) var quarterTurns = 0
    /// True when the iPhone can be controlled from here.
    private(set) var canControl = false

    var windowSize: WindowSize {
        didSet { UserDefaults.standard.set(windowSize.rawValue, forKey: "windowSize") }
    }

    let renderer = VideoRenderer()
    private let server = HeadsetServer()
    private var reconnectTimeout: Task<Void, Never>?
    private var pairedBannerTask: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        if let saved = defaults.string(forKey: "pairingCode"), TetherWire.normalized(saved).count == TetherConstants.codeLength {
            code = saved
        } else {
            let fresh = TetherWire.randomCode()
            defaults.set(fresh, forKey: "pairingCode")
            code = fresh
        }
        windowSize = WindowSize(rawValue: defaults.string(forKey: "windowSize") ?? "") ?? .medium

        renderer.onNeedsKeyframe = { [weak self] in self?.server.requestKeyframe() }
        renderer.onVideoSize = { [weak self] size in
            if self?.videoSize != size { self?.videoSize = size }
        }
        server.onEvent = { [weak self] event in self?.handle(event) }
    }

    var isLandscape: Bool { quarterTurns % 2 != 0 }

    /// Size of the upright picture, used for the window's aspect ratio.
    var displayAspect: CGFloat {
        let aspect = videoSize.width / max(videoSize.height, 1)
        return isLandscape ? 1 / aspect : aspect
    }

    func start() {
        server.start(code: code)
    }

    func stop() {
        server.stop()
    }

    // MARK: Control. Points are fractions (0...1) of the upright picture.

    func tap(at point: CGPoint) {
        server.send(TetherControl(kind: .tap, x: point.x, y: point.y))
    }

    func swipe(from start: CGPoint, to end: CGPoint, duration: TimeInterval) {
        server.send(TetherControl(kind: .swipe, x: start.x, y: start.y, endX: end.x, endY: end.y, duration: duration))
    }

    func longPress(at point: CGPoint, duration: TimeInterval) {
        server.send(TetherControl(kind: .longPress, x: point.x, y: point.y, duration: duration))
    }

    func type(_ text: String) {
        server.send(TetherControl(kind: .text, text: text))
    }

    func press(_ button: TetherControl.Button) {
        server.send(TetherControl(kind: .button, button: button))
    }

    func stopMirroring() {
        server.stopStream()
    }

    /// Invalidates the old code: every paired iPhone must pair again.
    func generateNewCode() {
        code = TetherWire.randomCode()
        UserDefaults.standard.set(code, forKey: "pairingCode")
        server.start(code: code)
    }

    private func handle(_ event: HeadsetServer.Event) {
        switch event {
        case .advertising(let name):
            headsetName = name
            listenerError = nil
        case .listenerFailed(let message):
            listenerError = message
        case .paired(let deviceName):
            recentlyPairedDevice = deviceName
            pairedBannerTask?.cancel()
            pairedBannerTask = Task {
                try? await Task.sleep(for: .seconds(6))
                if !Task.isCancelled { recentlyPairedDevice = nil }
            }
        case .capabilities(let capabilities):
            canControl = capabilities.control
        case .streamStarted(let hello):
            reconnectTimeout?.cancel()
            canControl = false
            recentlyPairedDevice = nil
            if hello.screenWidth > 0, hello.screenHeight > 0, case .waiting = phase {
                videoSize = CGSize(width: hello.screenWidth, height: hello.screenHeight)
            }
            if case .reconnecting = phase {
                phase = .mirroring(deviceName: hello.deviceName)
            } else {
                phase = .connecting(deviceName: hello.deviceName)
            }
            renderer.reset()
        case .format(let sps, let pps):
            renderer.installFormat(sps: sps, pps: pps)
        case .frame(let avcc, let isKeyframe, let orientation):
            // Only write on change: every write re-renders observing views.
            let turns = TetherGeometry.quarterTurns(for: orientation)
            if turns != quarterTurns { quarterTurns = turns }
            if renderer.enqueue(avcc: avcc, isKeyframe: isKeyframe), case .connecting(let name) = phase {
                phase = .mirroring(deviceName: name)
            }
        case .streamEnded:
            switch phase {
            case .mirroring(let name), .connecting(let name):
                // The broadcast extension retries for a while; keep the last
                // picture so a Wi-Fi blip does not flash the pairing screen.
                phase = .reconnecting(deviceName: name)
                reconnectTimeout?.cancel()
                reconnectTimeout = Task {
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled else { return }
                    phase = .waiting
                    canControl = false
                    renderer.reset()
                }
            case .waiting, .reconnecting:
                break
            }
        }
    }

}
