import CoreMedia
import Foundation
import OSLog
import os
import VideoToolbox

/// Hardware H.264 encoder tuned for interactive mirroring: no frame
/// reordering, low-latency rate control, and keyframes on demand.
final class VideoEncoder {
    struct Output {
        var parameterSets: (sps: Data, pps: Data)?
        var avcc: Data
        var isKeyframe: Bool
        var ptsMicros: UInt64
        var orientation: UInt8
    }

    /// Called on a VideoToolbox thread.
    var onOutput: ((Output) -> Void)?

    /// Longest encoded edge. Full iPhone resolution (2868 px) costs bandwidth
    /// and memory without a visible gain in a Vision Pro window.
    private let maxLongEdge = 1920
    private let logger = Logger(subsystem: "app.phoneremote.tether.broadcast", category: "Encoder")
    private var session: VTCompressionSession?
    private var encodedSize: (width: Int32, height: Int32) = (0, 0)
    private var sourceSize: (width: Int, height: Int) = (0, 0)
    /// Set from the network queue, read on the capture queue.
    private let forceKeyframe = OSAllocatedUnfairLock(initialState: true)

    func requestKeyframe() {
        forceKeyframe.withLock { $0 = true }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, orientation: UInt8) {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        if session == nil || sourceSize != (width, height) {
            makeSession(width: width, height: height)
        }
        guard let session else { return }

        var properties: CFDictionary?
        if forceKeyframe.withLock({ let wanted = $0; $0 = false; return wanted }) {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }

        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: properties,
            infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer else { return }
            self?.handle(sampleBuffer, orientation: orientation)
        }

        if status == kVTInvalidSessionErr {
            // The system tears sessions down when the app is interrupted.
            logger.error("Encoder session invalidated; rebuilding")
            invalidate()
        } else if status != noErr {
            logger.error("Encode failed: \(status)")
        }
    }

    func invalidate() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        requestKeyframe()
    }

    private func makeSession(width: Int, height: Int) {
        invalidate()
        sourceSize = (width, height)

        let scale = min(1, Double(maxLongEdge) / Double(max(width, height)))
        // H.264 needs even dimensions.
        let encodedWidth = Int32(Double(width) * scale) & ~1
        let encodedHeight = Int32(Double(height) * scale) & ~1
        encodedSize = (encodedWidth, encodedHeight)

        var lowLatencySpec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        var created: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil,
            width: encodedWidth,
            height: encodedHeight,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: lowLatencySpec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        if status != noErr {
            // Low-latency mode is unavailable on some hardware; fall back.
            lowLatencySpec = [:]
            status = VTCompressionSessionCreate(
                allocator: nil,
                width: encodedWidth,
                height: encodedHeight,
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &created
            )
        }
        guard status == noErr, let created else {
            logger.error("Could not create encoder: \(status)")
            return
        }

        let settings: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel,
            kVTCompressionPropertyKey_AverageBitRate: 8_000_000,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 4,
        ]
        for (key, value) in settings {
            VTSessionSetProperty(created, key: key, value: value as CFTypeRef)
        }
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
        requestKeyframe()
        logger.info("Encoder \(encodedWidth)x\(encodedHeight) from \(width)x\(height), low latency: \(!lowLatencySpec.isEmpty)")
    }

    private func handle(_ sampleBuffer: CMSampleBuffer, orientation: UInt8) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        var parameterSets: (Data, Data)?
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            parameterSets = Self.parameterSets(of: format)
        }

        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer
        ) == kCMBlockBufferNoErr, let pointer else { return }
        // VideoToolbox emits AVCC (4-byte length prefixes), which is what the
        // viewer's AVSampleBufferDisplayLayer expects, so no rewriting is needed.
        let avcc = Data(bytes: pointer, count: length)

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let micros = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000)) : 0
        onOutput?(Output(parameterSets: parameterSets, avcc: avcc, isKeyframe: isKeyframe, ptsMicros: micros, orientation: orientation))
    }

    private static func parameterSets(of format: CMFormatDescription) -> (Data, Data)? {
        func set(at index: Int) -> Data? {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            guard CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil
            ) == noErr, let pointer else { return nil }
            return Data(bytes: pointer, count: size)
        }
        guard let sps = set(at: 0), let pps = set(at: 1) else { return nil }
        return (sps, pps)
    }
}
