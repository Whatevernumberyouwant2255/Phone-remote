import Foundation

/// Measures where control and video latency come from and prints it, for
/// reading from the Mac with `devicectl device process launch --console`.
/// Invisible in the app. Network-queue methods run on the server's queue.
final class LatencyProbe: @unchecked Sendable {
    private struct Pending {
        var kind: String
        var sentAt: TimeInterval
    }

    private var nextID: UInt32 = 0
    private var pending: [UInt32: Pending] = [:]
    /// Controls sent since the last frame. The iPhone sends frames only when
    /// its screen changes, so the first frame after a control is (on a still
    /// screen) the moment its effect became visible.
    private var awaitingFrame: [(id: UInt32, kind: String, sentAt: TimeInterval)] = []

    // Video statistics over the current window.
    private var windowStart = now()
    private var frames = 0
    private var keyframes = 0
    private var bytes = 0
    private var lastFrameAt: TimeInterval?
    private var maxGap: TimeInterval = 0

    // Main-thread hop, written on main and read on the network queue.
    private let hopLock = NSLock()
    private var hopTotal: TimeInterval = 0
    private var hopMax: TimeInterval = 0
    private var hopCount = 0

    /// stderr is unbuffered, so lines reach the Mac console immediately.
    private func report(_ line: String) {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Network queue

    func controlSent(_ control: inout TetherControl) {
        nextID &+= 1
        control.id = nextID
        let kind = control.kind == .swipe
            ? String(format: "swipe(%.2fs)", control.duration)
            : control.kind.rawValue
        let now = Self.now()
        pending[nextID] = Pending(kind: kind, sentAt: now)
        awaitingFrame.append((nextID, kind, now))
    }

    func ackReceived(_ ack: TetherControlAck) {
        guard let entry = pending.removeValue(forKey: ack.id) else { return }
        let now = Self.now()
        let roundTrip = (now - entry.sentAt) * 1000
        let network = roundTrip - ack.queueMs - ack.deviceKitMs
        report(String(format: "TETHER control %@ #%u: round trip %.0f ms = network+overhead %.0f + waiting %.0f + DeviceKit %.0f",
                     entry.kind, ack.id, roundTrip, network, ack.queueMs, ack.deviceKitMs))
    }

    func frameReceived(bytes size: Int, isKeyframe: Bool) {
        let now = Self.now()
        let stillBefore = lastFrameAt.map { now - $0 } ?? 0
        for control in awaitingFrame {
            report(String(format: "TETHER control %@ #%u: FIRST NEW FRAME %.0f ms after the pinch (screen was still for %.0f ms before)",
                          control.kind, control.id, (now - control.sentAt) * 1000, stillBefore * 1000))
        }
        awaitingFrame.removeAll()

        frames += 1
        bytes += size
        if isKeyframe { keyframes += 1 }
        if let last = lastFrameAt { maxGap = max(maxGap, now - last) }
        lastFrameAt = now

        let elapsed = now - windowStart
        guard elapsed >= 5 else { return }
        let (hopAverage, hopWorst) = hopLock.withLock {
            defer { hopTotal = 0; hopMax = 0; hopCount = 0 }
            return (hopCount > 0 ? hopTotal / Double(hopCount) : 0, hopMax)
        }
        report(String(format: "TETHER video: %.0f fps, %.1f Mbit/s, %d keyframes, longest gap %.0f ms, main-thread wait avg %.1f ms max %.0f ms",
                     Double(frames) / elapsed, Double(bytes) * 8 / elapsed / 1_000_000, keyframes, maxGap * 1000,
                     hopAverage * 1000, hopWorst * 1000))
        windowStart = now
        frames = 0
        keyframes = 0
        bytes = 0
        maxGap = 0
    }

    func stamp() -> TimeInterval { Self.now() }

    // MARK: Main thread

    func frameReachedMain(stampedAt: TimeInterval) {
        let wait = Self.now() - stampedAt
        hopLock.withLock {
            hopTotal += wait
            hopMax = max(hopMax, wait)
            hopCount += 1
        }
    }
}
