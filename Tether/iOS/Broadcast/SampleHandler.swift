import CoreMedia
import ImageIO
import OSLog
import ReplayKit
import UIKit

/// Receives the screen from ReplayKit, encodes it and streams it to the
/// paired headset for as long as the broadcast runs.
final class SampleHandler: RPBroadcastSampleHandler {
    private let logger = Logger(subsystem: "app.phoneremote.tether.broadcast", category: "Broadcast")
    private let queue = DispatchQueue(label: "app.phoneremote.tether.broadcast.network", qos: .userInteractive)
    private let encoder = VideoEncoder()
    private let deviceKit = DeviceKitBridge()

    // Everything below is touched only on `queue`.
    private var pairing: Pairing?
    private var link: HeadsetLink?
    private var hasConnectedOnce = false
    private var failedAttempts = 0
    private var stopped = false
    private var waitingForKeyframe = true
    private var lastParameterSets: (sps: Data, pps: Data)?
    private var capabilities: TetherCapabilities?
    private var probeTask: Task<Void, Never>?
    private var lastControlTime = Date.distantPast
    private var lastKeepAwakeTime = Date.distantPast

    /// Past this backlog the Wi-Fi cannot keep up; drop frames until the
    /// next keyframe rather than let latency grow.
    private let maxBytesInFlight = 1_500_000

    /// Serializes the encoder between ReplayKit's sample queue and resends.
    private let captureLock = NSLock()
    // Guarded by `captureLock`.
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastOrientation: UInt8 = 1

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        guard !PairingStore.all().isEmpty else {
            finish(String(localized: "Open Phone Remote on your iPhone and pair it with your Apple Vision Pro or Mac first."))
            return
        }
        encoder.onOutput = { [weak self] output in
            self?.queue.async { self?.send(output) }
        }
        queue.async { self.connect() }
    }

    override func broadcastFinished() {
        queue.sync {
            stopped = true
            probeTask?.cancel()
            link?.stop(sayGoodbye: true)
            link = nil
        }
        captureLock.withLock {
            lastPixelBuffer = nil
            encoder.invalidate()
        }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let orientation = (CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString, attachmentModeOut: nil) as? NSNumber)?.uint8Value ?? 1
        captureLock.withLock {
            lastPixelBuffer = pixelBuffer
            lastOrientation = orientation
            encoder.encode(pixelBuffer, pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), orientation: orientation)
        }
    }

    // MARK: - Network

    /// Mirrors to whichever paired receiver has Phone Remote open, preferring
    /// the one used most recently. Chosen again on every attempt, so closing
    /// the app on one device and opening it on another switches over.
    private func connect() {
        guard !stopped else { return }
        ReceiverFinder.find(timeout: 1.5, queue: queue) { [weak self] available in
            guard let self, !self.stopped else { return }
            let pairings = PairingStore.all()
            guard let target = pairings.first(where: { available.contains($0.serviceName) }) ?? pairings.first else {
                self.finish(String(localized: "Open Phone Remote on your iPhone and pair it with your Apple Vision Pro or Mac first."))
                return
            }
            self.connect(to: target)
        }
    }

    private func connect(to pairing: Pairing) {
        self.pairing = pairing
        let hello = TetherHello(
            purpose: .stream,
            deviceName: UIDevice.current.name,
            screenWidth: Int(UIScreen.main.nativeBounds.width),
            screenHeight: Int(UIScreen.main.nativeBounds.height)
        )
        let link = HeadsetLink(serviceName: pairing.serviceName, code: pairing.code, hello: hello, queue: queue)
        link.onEvent = { [weak self, weak link] event in
            guard let self, let link, link === self.link else { return }
            self.handle(event)
        }
        self.link = link
        link.start()
    }

    private func handle(_ event: HeadsetLink.Event) {
        switch event {
        case .ready(let welcome):
            logger.info("Streaming to \(welcome.headsetName, privacy: .public)")
            hasConnectedOnce = true
            if let pairing { PairingStore.markUsed(pairing.serviceName) }
            failedAttempts = 0
            waitingForKeyframe = true
            lastParameterSets = nil
            encoder.requestKeyframe()
            // ReplayKit sends nothing while the screen is still, so repeat
            // the last picture to show something immediately.
            resendLastFrame()
            capabilities = nil
            startProbingDeviceKit()
        case .keyframeRequested:
            encoder.requestKeyframe()
            resendLastFrame()
        case .control(let control):
            guard capabilities?.control == true else { return }
            lastControlTime = .now
            let portrait = UIScreen.main.bounds.size
            let turns = TetherGeometry.quarterTurns(for: captureLock.withLock { lastOrientation })
            deviceKit.perform(control, portrait: CGSize(width: min(portrait.width, portrait.height), height: max(portrait.width, portrait.height)), quarterTurns: turns) { [weak self] queueMs, deviceKitMs in
                guard let id = control.id else { return }
                self?.queue.async {
                    self?.link?.send(TetherWire.encode(.controlAck, json: TetherControlAck(id: id, queueMs: queueMs, deviceKitMs: deviceKitMs)))
                }
            }
        case .closedByHeadset:
            finish(String(localized: "Mirroring was stopped from Apple Vision Pro."))
        case .failed(.wrongCode):
            finish(String(localized: "The pairing code no longer matches \(pairing?.headsetName ?? "Phone Remote"). Open Phone Remote on your iPhone to pair again."))
        case .failed(.unreachable(let reason)):
            failedAttempts += 1
            logger.error("Connection attempt \(self.failedAttempts) failed: \(reason, privacy: .public)")
            // Before the first connection, give up after ~20 s so the user
            // learns what is wrong. Afterwards, keep trying: Wi-Fi hiccups.
            if !hasConnectedOnce && failedAttempts >= 10 {
                let name = pairing?.headsetName ?? "Phone Remote"
                finish(String(localized: "Couldn't reach \(name). Open Phone Remote on it and make sure both devices are on the same Wi-Fi network."))
                return
            }
            link = nil
            queue.asyncAfter(deadline: .now() + (hasConnectedOnce ? 1 : 2)) { [weak self] in self?.connect() }
        }
    }

    /// Checks for DeviceKit now and every few seconds, so starting it during
    /// a session turns control on without reconnecting.
    private func startProbingDeviceKit() {
        probeTask?.cancel()
        probeTask = Task { [weak self] in
            while !Task.isCancelled, let self {
                let available = await self.deviceKit.isAvailable()
                self.queue.async {
                    self.updateCapabilities(TetherCapabilities(control: available))
                    if available { self.keepAwakeIfIdle() }
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func updateCapabilities(_ new: TetherCapabilities) {
        guard new != capabilities, let link, link.isReady else { return }
        capabilities = new
        logger.info("Remote control available: \(new.control)")
        link.send(TetherWire.encode(.capabilities, json: new))
    }

    /// Auto-lock would end the broadcast. Real touches already reset it, so
    /// only nudge when nobody has touched the phone for a while.
    private func keepAwakeIfIdle() {
        let now = Date.now
        guard now.timeIntervalSince(lastControlTime) > 15,
              now.timeIntervalSince(lastKeepAwakeTime) > 20 else { return }
        lastKeepAwakeTime = now
        deviceKit.keepAwake()
    }

    private func send(_ output: VideoEncoder.Output) {
        guard let link, link.isReady else { return }

        if link.bytesInFlight > maxBytesInFlight {
            waitingForKeyframe = true
            encoder.requestKeyframe()
            return
        }
        if waitingForKeyframe {
            guard output.isKeyframe else { return }
            waitingForKeyframe = false
        }
        if let sets = output.parameterSets, lastParameterSets.map({ $0.sps != sets.sps || $0.pps != sets.pps }) ?? true {
            lastParameterSets = sets
            link.send(TetherWire.encode(.format, TetherWire.formatPayload(sps: sets.sps, pps: sets.pps)))
        }
        link.send(TetherWire.encode(.frame, TetherWire.framePayload(
            avcc: output.avcc,
            isKeyframe: output.isKeyframe,
            orientation: output.orientation,
            ptsMicros: output.ptsMicros
        )))
    }

    private func resendLastFrame() {
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            guard let self else { return }
            self.captureLock.withLock {
                guard let buffer = self.lastPixelBuffer else { return }
                self.encoder.encode(buffer, pts: CMClockGetTime(CMClockGetHostTimeClock()), orientation: self.lastOrientation)
            }
        }
    }

    private func finish(_ message: String) {
        stopped = true
        probeTask?.cancel()
        link?.stop(sayGoodbye: false)
        link = nil
        finishBroadcastWithError(NSError(
            domain: "app.phoneremote.tether",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        ))
    }
}
