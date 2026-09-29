import Foundation
import Network
import OSLog

/// One encrypted connection from the iPhone to a Tether headset. All callbacks
/// and state live on `queue`.
final class HeadsetLink: @unchecked Sendable {
    enum Event {
        /// The TLS handshake succeeded (so the code matched) and the headset answered.
        case ready(TetherWelcome)
        case keyframeRequested
        case control(TetherControl)
        /// The headset ended the session on purpose.
        case closedByHeadset
        case failed(Failure)
    }

    enum Failure: Error {
        /// TLS rejected the key: the code does not match the headset.
        case wrongCode
        case unreachable(String)
    }

    let queue: DispatchQueue
    var onEvent: ((Event) -> Void)?

    private let endpoint: NWEndpoint
    private let code: String
    private let hello: TetherHello
    private let logger = Logger(subsystem: "app.phoneremote.tether", category: "HeadsetLink")
    private var connection: NWConnection?
    private var reader = TetherMessageReader()
    private var welcomed = false
    private var finished = false
    /// Bytes handed to the network that it has not yet sent.
    private(set) var bytesInFlight = 0

    init(endpoint: NWEndpoint, code: String, hello: TetherHello, queue: DispatchQueue) {
        self.endpoint = endpoint
        self.code = code
        self.hello = hello
        self.queue = queue
    }

    convenience init(serviceName: String, code: String, hello: TetherHello, queue: DispatchQueue) {
        self.init(
            endpoint: .service(name: serviceName, type: TetherConstants.serviceType, domain: "local.", interface: nil),
            code: code,
            hello: hello,
            queue: queue
        )
    }

    var isReady: Bool { welcomed && !finished }

    func start() {
        let connection = NWConnection(to: endpoint, using: TetherWire.parameters(code: code))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            self?.handle(state)
        }
        connection.start(queue: queue)
    }

    /// Sends one encoded message. Must be called on `queue`.
    func send(_ message: Data) {
        guard isReady, let connection else { return }
        bytesInFlight += message.count
        connection.send(content: message, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.bytesInFlight -= message.count
            if let error { self.fail(.unreachable(error.localizedDescription)) }
        })
    }

    /// Ends the session. Must be called on `queue`.
    func stop(sayGoodbye: Bool) {
        guard !finished else { return }
        finished = true
        guard let connection else { return }
        if sayGoodbye, welcomed {
            connection.send(content: TetherWire.encode(.goodbye), isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            connection.cancel()
        }
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            connection?.send(content: TetherWire.encode(.hello, json: hello), completion: .idempotent)
            receive()
        case .waiting(let error), .failed(let error):
            fail(Self.classify(error))
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !self.finished else { return }
            if let data { self.reader.append(data) }
            do {
                while let (type, payload) = try self.reader.next() {
                    self.dispatch(type, payload)
                }
            } catch {
                self.fail(.unreachable("Invalid data from headset"))
                return
            }
            if let error {
                self.fail(Self.classify(error))
            } else if isComplete {
                self.fail(.unreachable("The headset closed the connection"))
            } else {
                self.receive()
            }
        }
    }

    private func dispatch(_ type: TetherMessageType?, _ payload: Data) {
        switch type {
        case .welcome:
            guard !welcomed, let welcome = try? JSONDecoder().decode(TetherWelcome.self, from: payload) else { return }
            welcomed = true
            onEvent?(.ready(welcome))
        case .keyframeRequest:
            onEvent?(.keyframeRequested)
        case .controlAck:
            break
        case .control:
            if let control = try? JSONDecoder().decode(TetherControl.self, from: payload) {
                onEvent?(.control(control))
            }
        case .goodbye:
            finished = true
            connection?.cancel()
            onEvent?(.closedByHeadset)
        default:
            break
        }
    }

    private func fail(_ failure: Failure) {
        guard !finished else { return }
        finished = true
        connection?.cancel()
        logger.error("Link failed: \(String(describing: failure), privacy: .public)")
        onEvent?(.failed(failure))
    }

    private static func classify(_ error: NWError) -> Failure {
        if case .tls = error { return .wrongCode }
        return .unreachable(error.localizedDescription)
    }
}
