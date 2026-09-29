import AVFoundation
import CoreMedia
import OSLog

/// Decodes and shows the iPhone's H.264 stream with the system video layer.
@MainActor
final class VideoRenderer {
    var onNeedsKeyframe: (() -> Void)?
    var onVideoSize: ((CGSize) -> Void)?

    let displayLayer = AVSampleBufferDisplayLayer()
    private let logger = Logger(subsystem: "app.phoneremote.tether", category: "Video")
    private var formatDescription: CMVideoFormatDescription?
    private var lastSPS: Data?
    private var lastPPS: Data?
    private var waitingForKeyframe = true

    init() {
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func reset() {
        formatDescription = nil
        lastSPS = nil
        lastPPS = nil
        waitingForKeyframe = true
    }

    func installFormat(sps: Data, pps: Data) {
        // The iPhone repeats identical parameter sets with each keyframe;
        // reinstalling them would flush the picture every few seconds.
        guard formatDescription == nil || sps != lastSPS || pps != lastPPS else { return }

        var description: CMFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { spsBytes in
            pps.withUnsafeBytes { ppsBytes in
                guard let spsBase = spsBytes.bindMemory(to: UInt8.self).baseAddress,
                      let ppsBase = ppsBytes.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                let pointers = [spsBase, ppsBase]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &description
                )
            }
        }
        guard status == noErr, let description else {
            logger.error("Invalid H.264 parameter sets: \(status)")
            onNeedsKeyframe?()
            return
        }
        formatDescription = description
        lastSPS = sps
        lastPPS = pps
        waitingForKeyframe = true
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        onVideoSize?(CGSize(width: Int(dimensions.width), height: Int(dimensions.height)))
    }

    /// Returns true when the frame was handed to the display.
    @discardableResult
    func enqueue(avcc: Data, isKeyframe: Bool) -> Bool {
        guard let formatDescription else {
            onNeedsKeyframe?()
            return false
        }
        if waitingForKeyframe {
            guard isKeyframe else { return false }
            waitingForKeyframe = false
        }

        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            logger.error("Decoder stalled: \(renderer.error?.localizedDescription ?? "unknown", privacy: .public)")
            renderer.flush()
            waitingForKeyframe = true
            onNeedsKeyframe?()
            return false
        }

        guard let sampleBuffer = Self.sampleBuffer(avcc: avcc, format: formatDescription) else { return false }
        renderer.enqueue(sampleBuffer)
        return true
    }

    private static func sampleBuffer(avcc: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: avcc.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        ) == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copied = avcc.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        guard CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        // Untimed samples stay black unless marked for immediate display on
        // the per-sample attachment dictionary.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [NSMutableDictionary],
           let first = attachments.first {
            first[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        return sampleBuffer
    }
}
