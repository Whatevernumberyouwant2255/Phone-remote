import Foundation
import Network
import OSLog

/// Advertises this headset on the local network and accepts iPhones that know
/// the pairing code. All state lives on `queue`; callbacks arrive on main.
final class HeadsetServer: @unchecked Sendable {
    enum Event {
        case advertising(name: String)
        case listenerFailed(String)
        case paired(deviceName: String)
        case streamStarted(TetherHello)
        case format(sps: Data, pps: Data)
        case frame(avcc: Data, isKeyframe: Bool, orientation: UInt8)
        case capabilities(TetherCapabilities)
        case streamEnded
    }

    var onEvent: (@MainActor (Event) -> Void)?

    private let logger = Logger(subsystem: "app.phoneremote.tether", category: "Server")
    private let queue = DispatchQueue(label: "app.phoneremote.tether.server", qos: .userInteractive)
    private var listener: NWListener?
    private var code = ""
    private var headsetName = ReceiverKind.current.genericName
    /// The connection currently streaming video. A newer stream replaces it.
    private var streamConnection: NWConnection?
    private let probe = LatencyProbe()

    /// Starts advertising, or restarts with a new code. Does nothing if
    /// already running with `code`, so an active stream survives.
    func start(code: String) {
        queue.async {
            guard self.listener == nil || code != self.code else { return }
            self.restart(code: code)
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            self.endStream(sayGoodbye: true)
        }
    }

    func requestKeyframe() {
        queue.async {
            self.streamConnection?.send(content: TetherWire.encode(.keyframeRequest), completion: .idempotent)
        }
    }

    func send(_ control: TetherControl) {
        queue.async {
            guard self.streamConnection != nil else { return }
            var control = control
            self.probe.controlSent(&control)
            self.streamConnection?.send(content: TetherWire.encode(.control, json: control), completion: .idempotent)
        }
    }

    /// Asks the iPhone to end its broadcast.
    func stopStream() {
        queue.async { self.endStream(sayGoodbye: true) }
    }

    private func restart(code: String) {
        listener?.cancel()
        endStream(sayGoodbye: true)
        self.code = code

        do {
            let listener = try NWListener(using: TetherWire.parameters(code: code))
            // A nil name lets the system use this headset's own device name.
            listener.service = NWListener.Service(
                type: TetherConstants.serviceType,
                txtRecord: NWTXTRecord([TetherConstants.kindKey: ReceiverKind.current.rawValue]).data
            )
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                guard let self, case .add(let endpoint) = change,
                      case .service(let name, _, _, _) = endpoint else { return }
                self.headsetName = name
                self.emit(.advertising(name: name))
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, listener === self.listener else { return }
                if case .failed(let error) = state {
                    self.logger.error("Listener failed: \(error.localizedDescription, privacy: .public)")
                    self.emit(.listenerFailed(error.localizedDescription))
                    // Typically the network changed; try again shortly.
                    self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.listener === listener else { return }
                        self.restart(code: self.code)
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            emit(.listenerFailed(error.localizedDescription))
        }
    }

    private func accept(_ connection: NWConnection) {
        var reader = TetherMessageReader()
        var hello: TetherHello?

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { reader.append(data) }
                do {
                    while let (type, payload) = try reader.next() {
                        self.dispatch(type, payload, from: connection, hello: &hello)
                    }
                } catch {
                    connection.cancel()
                    return
                }
                if error != nil || isComplete {
                    connection.cancel()
                } else {
                    receive()
                }
            }
        }

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                receive()
            case .failed, .cancelled:
                if connection === self.streamConnection {
                    self.streamConnection = nil
                    self.emit(.streamEnded)
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func dispatch(_ type: TetherMessageType?, _ payload: Data, from connection: NWConnection, hello: inout TetherHello?) {
        switch type {
        case .hello:
            guard hello == nil, let received = try? JSONDecoder().decode(TetherHello.self, from: payload) else {
                connection.cancel()
                return
            }
            hello = received
            connection.send(
                content: TetherWire.encode(.welcome, json: TetherWelcome(headsetName: headsetName)),
                completion: .idempotent
            )
            switch received.purpose {
            case .pair:
                emit(.paired(deviceName: received.deviceName))
            case .stream:
                if let previous = streamConnection, previous !== connection {
                    previous.cancel()
                }
                streamConnection = connection
                emit(.streamStarted(received))
            }
        case .format:
            guard connection === streamConnection, let sets = TetherWire.parseFormat(payload) else { return }
            emit(.format(sps: sets.sps, pps: sets.pps))
        case .frame:
            guard connection === streamConnection, let frame = TetherWire.parseFrame(payload) else { return }
            probe.frameReceived(bytes: frame.avcc.count, isKeyframe: frame.isKeyframe)
            let stamp = probe.stamp()
            let probe = probe
            let handler = onEvent
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    probe.frameReachedMain(stampedAt: stamp)
                    handler?(.frame(avcc: frame.avcc, isKeyframe: frame.isKeyframe, orientation: frame.orientation))
                }
            }
        case .capabilities:
            guard connection === streamConnection,
                  let capabilities = try? JSONDecoder().decode(TetherCapabilities.self, from: payload) else { return }
            emit(.capabilities(capabilities))
        case .goodbye:
            connection.cancel()
        case .controlAck:
            guard connection === streamConnection,
                  let ack = try? JSONDecoder().decode(TetherControlAck.self, from: payload) else { return }
            probe.ackReceived(ack)
        case .welcome, .keyframeRequest, .control, .none:
            break
        }
    }

    private func endStream(sayGoodbye: Bool) {
        guard let connection = streamConnection else { return }
        streamConnection = nil
        if sayGoodbye {
            connection.send(content: TetherWire.encode(.goodbye), isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } else {
            connection.cancel()
        }
        emit(.streamEnded)
    }

    private func emit(_ event: Event) {
        let handler = onEvent
        DispatchQueue.main.async {
            MainActor.assumeIsolated { handler?(event) }
        }
    }
}
