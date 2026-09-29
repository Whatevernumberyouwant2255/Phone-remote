import Foundation
import Network
import Observation
import UIKit

@MainActor
@Observable
final class AppModel {
    /// A Vision Pro or Mac with Phone Remote open, found on the network.
    struct Receiver: Identifiable, Hashable {
        var id: String { serviceName }
        var serviceName: String
        var kind: ReceiverKind
    }

    enum PairingError: LocalizedError {
        case wrongCode
        case unreachable
        case timedOut

        var errorDescription: String? {
            switch self {
            case .wrongCode:
                String(localized: "That code doesn't match. Check the code shown in Phone Remote on that device.")
            case .unreachable, .timedOut:
                String(localized: "Couldn't reach that device. Keep Phone Remote open on it and make sure both devices are on the same Wi-Fi network.")
            }
        }
    }

    private(set) var pairings: [Pairing] = PairingStore.all()
    private(set) var receivers: [Receiver] = []
    private(set) var browserFailed = false
    /// True while the screen is being broadcast (or mirrored another way).
    private(set) var isMirroring = UIScreen.main.isCaptured {
        didSet { UIApplication.shared.isIdleTimerDisabled = isMirroring }
    }
    /// Whether DeviceKit answers, so the headset can control this iPhone.
    private(set) var controlAvailable = false
    private let deviceKit = DeviceKitBridge()

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "app.phoneremote.tether.app")

    init() {
        NotificationCenter.default.addObserver(
            forName: UIScreen.capturedDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.isMirroring = UIScreen.main.isCaptured }
        }
    }

    func startBrowsing() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: TetherConstants.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Receiver? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var kind = ReceiverKind.visionPro
                if case .bonjour(let txt) = result.metadata,
                   let value = txt[TetherConstants.kindKey], let parsed = ReceiverKind(rawValue: value) {
                    kind = parsed
                }
                return Receiver(serviceName: name, kind: kind)
            }
            Task { @MainActor in
                self?.receivers = Array(Set(found)).sorted { $0.serviceName < $1.serviceName }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .failed, .waiting:
                    // Usually local-network access was declined.
                    self?.browserFailed = true
                case .ready:
                    self?.browserFailed = false
                default:
                    break
                }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func refreshControlStatus() async {
        controlAvailable = await deviceKit.isAvailable()
    }

    /// Returns false when this DeviceKit build has no stop command (started
    /// before the command existed); then it has to be stopped from the Mac.
    func turnOffControl() async -> Bool {
        let stopped = await deviceKit.stop()
        if stopped { controlAvailable = false }
        return stopped
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
    }

    /// Connects once with `code`; saves the pairing only if the headset accepts it.
    func isOpen(_ pairing: Pairing) -> Bool {
        receivers.contains { $0.serviceName == pairing.serviceName }
    }

    func isPaired(_ receiver: Receiver) -> Bool {
        pairings.contains { $0.serviceName == receiver.serviceName }
    }

    func pair(with receiver: Receiver, code: String) async throws {
        let hello = TetherHello(
            purpose: .pair,
            deviceName: UIDevice.current.name,
            screenWidth: Int(UIScreen.main.nativeBounds.width),
            screenHeight: Int(UIScreen.main.nativeBounds.height)
        )
        let link = HeadsetLink(serviceName: receiver.serviceName, code: code, hello: hello, queue: queue)

        let welcome: TetherWelcome = try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let resume: (Result<TetherWelcome, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                link.stop(sayGoodbye: true)
                continuation.resume(with: result)
            }
            link.onEvent = { event in
                switch event {
                case .ready(let welcome): resume(.success(welcome))
                case .failed(.wrongCode): resume(.failure(PairingError.wrongCode))
                case .failed, .closedByHeadset: resume(.failure(PairingError.unreachable))
                case .keyframeRequested, .control: break
                }
            }
            queue.async { link.start() }
            queue.asyncAfter(deadline: .now() + 10) { resume(.failure(PairingError.timedOut)) }
        }

        PairingStore.upsert(Pairing(
            serviceName: receiver.serviceName,
            headsetName: welcome.headsetName,
            code: TetherWire.normalized(code),
            kind: receiver.kind,
            lastUsed: .now
        ))
        pairings = PairingStore.all()
    }

    func forget(_ pairing: Pairing) {
        PairingStore.remove(pairing.serviceName)
        pairings = PairingStore.all()
    }

    /// Picks up `lastUsed` changes made by the broadcast extension.
    func reloadPairings() {
        pairings = PairingStore.all()
    }
}
