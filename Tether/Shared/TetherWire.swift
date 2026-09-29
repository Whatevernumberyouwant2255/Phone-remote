import CryptoKit
import Foundation
import Network

/// Constants shared by the iPhone app, its broadcast extension and the
/// Vision Pro viewer.
enum TetherConstants {
    static let serviceType = "_tether._tcp"
    static let protocolVersion = 1
    static let appGroup = "group.app.phoneremote.tether"
    static let broadcastExtensionID = "app.phoneremote.tether.broadcast"
    /// Characters that cannot be mistaken for one another when typed.
    static let codeAlphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    static let codeLength = 8
    /// Bonjour TXT key telling the iPhone what kind of device is receiving.
    static let kindKey = "kind"
}

/// A device that shows the iPhone's screen.
enum ReceiverKind: String, Codable {
    case visionPro = "vision"
    case mac

    /// Shown until Bonjour reports this device's own name.
    var genericName: String {
        switch self {
        case .visionPro: "Apple Vision Pro"
        case .mac: "Mac"
        }
    }

    #if os(macOS)
    static let current = ReceiverKind.mac
    #else
    static let current = ReceiverKind.visionPro
    #endif
}

/// Every message is `[UInt32 length][UInt8 type][payload]`, big-endian, where
/// `length` counts the type byte and the payload.
enum TetherMessageType: UInt8 {
    /// iPhone → headset. JSON `Hello`.
    case hello = 0x01
    /// Headset → iPhone. JSON `Welcome`.
    case welcome = 0x02
    /// iPhone → headset. `[UInt16 spsLength][sps][UInt16 ppsLength][pps]`.
    case format = 0x03
    /// iPhone → headset. `[UInt8 flags][UInt8 orientation][UInt64 ptsMicros][AVCC NAL units]`.
    case frame = 0x04
    /// Headset → iPhone. Empty payload.
    case keyframeRequest = 0x05
    /// Either direction. Empty payload; the sender is ending the session.
    case goodbye = 0x06
    /// iPhone → headset. JSON `TetherCapabilities`.
    case capabilities = 0x07
    /// Headset → iPhone. JSON `TetherControl`.
    case control = 0x08
    /// iPhone → headset. JSON `TetherControlAck`, sent once a control is done.
    case controlAck = 0x09
}

/// Timing for one control, used to measure where latency comes from.
struct TetherControlAck: Codable {
    var id: UInt32
    /// Time spent waiting behind earlier controls on the iPhone.
    var queueMs: Double
    /// Time DeviceKit took to perform the control.
    var deviceKitMs: Double
}

struct TetherCapabilities: Codable, Equatable {
    /// True when the optional DeviceKit runner answers on the iPhone.
    var control: Bool
}

/// A touch or button from the headset. Coordinates are fractions (0...1) of
/// the picture as displayed upright, so they do not depend on window size.
struct TetherControl: Codable {
    enum Kind: String, Codable {
        case tap, swipe, text, button
        /// Touch and hold at `x`, `y` for `duration` seconds.
        case longPress
    }

    enum Button: String, Codable {
        case home, lock, volumeUp, volumeDown
        /// Performed as gestures, not hardware buttons.
        case appSwitcher, spotlight
    }

    var kind: Kind
    var x: Double = 0
    var y: Double = 0
    var endX: Double = 0
    var endY: Double = 0
    var duration: Double = 0.25
    var text: String?
    var button: Button?
    /// Set by the headset to match the iPhone's `TetherControlAck`.
    var id: UInt32?
}

struct TetherHello: Codable {
    enum Purpose: String, Codable {
        /// The iPhone app is checking the pairing code.
        case pair
        /// The broadcast extension is about to stream.
        case stream
    }

    var version = TetherConstants.protocolVersion
    var purpose: Purpose
    var deviceName: String
    var screenWidth: Int
    var screenHeight: Int
}

struct TetherWelcome: Codable {
    var version = TetherConstants.protocolVersion
    var headsetName: String
}

enum TetherWire {
    static let maxMessageSize = 8 * 1024 * 1024

    static func encode(_ type: TetherMessageType, _ payload: Data = Data()) -> Data {
        var length = UInt32(payload.count + 1).bigEndian
        var message = Data(capacity: payload.count + 5)
        withUnsafeBytes(of: &length) { message.append(contentsOf: $0) }
        message.append(type.rawValue)
        message.append(payload)
        return message
    }

    static func encode<T: Encodable>(_ type: TetherMessageType, json value: T) -> Data {
        encode(type, (try? JSONEncoder().encode(value)) ?? Data())
    }

    static func formatPayload(sps: Data, pps: Data) -> Data {
        var payload = Data()
        payload.appendBigEndian(UInt16(sps.count))
        payload.append(sps)
        payload.appendBigEndian(UInt16(pps.count))
        payload.append(pps)
        return payload
    }

    static func parseFormat(_ payload: Data) -> (sps: Data, pps: Data)? {
        var reader = ByteReader(payload)
        guard let spsLength = reader.readUInt16(),
              let sps = reader.read(Int(spsLength)),
              let ppsLength = reader.readUInt16(),
              let pps = reader.read(Int(ppsLength)) else { return nil }
        return (sps, pps)
    }

    static func framePayload(avcc: Data, isKeyframe: Bool, orientation: UInt8, ptsMicros: UInt64) -> Data {
        var payload = Data(capacity: avcc.count + 10)
        payload.append(isKeyframe ? 1 : 0)
        payload.append(orientation)
        payload.appendBigEndian(ptsMicros)
        payload.append(avcc)
        return payload
    }

    static func parseFrame(_ payload: Data) -> (avcc: Data, isKeyframe: Bool, orientation: UInt8)? {
        var reader = ByteReader(payload)
        guard let flags = reader.readUInt8(),
              let orientation = reader.readUInt8(),
              reader.readUInt64() != nil else { return nil }
        return (reader.remaining(), flags & 1 == 1, orientation)
    }

    /// TLS 1.2 with a pre-shared key derived from the pairing code. Both sides
    /// must hold the same code or the handshake fails, so the video is never
    /// readable by other devices on the network.
    static func parameters(code: String) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let secret = SymmetricKey(data: Data(normalized(code).utf8))
        let key = HMAC<SHA256>.authenticationCode(for: Data("Tether pairing v1".utf8), using: secret)
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data("tether".utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            tls.securityProtocolOptions,
            keyData as __DispatchData,
            identity as __DispatchData
        )
        sec_protocol_options_append_tls_ciphersuite(
            tls.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        parameters.serviceClass = .interactiveVideo
        return parameters
    }

    /// Upper-cases the code and removes separators, so "abcd-efgh" and
    /// "ABCDEFGH" derive the same key.
    static func normalized(_ code: String) -> String {
        code.uppercased().filter { TetherConstants.codeAlphabet.contains($0) }
    }

    static func randomCode() -> String {
        String((0..<TetherConstants.codeLength).map { _ in TetherConstants.codeAlphabet.randomElement()! })
    }

    /// "ABCD2345" → "ABCD-2345".
    static func displayCode(_ code: String) -> String {
        let code = normalized(code)
        guard code.count == TetherConstants.codeLength else { return code }
        let middle = code.index(code.startIndex, offsetBy: TetherConstants.codeLength / 2)
        return "\(code[..<middle])-\(code[middle...])"
    }
}

/// ReplayKit always delivers portrait pictures plus the phone's orientation
/// (a CGImagePropertyOrientation raw value). The headset rotates the picture
/// upright; touches must be rotated back before reaching the iPhone.
enum TetherGeometry {
    /// Quarter turns clockwise that show the portrait picture upright.
    static func quarterTurns(for orientation: UInt8) -> Int {
        switch orientation {
        case 3, 4: 2 // down, downMirrored
        case 5, 8: 1 // leftMirrored, left
        case 6, 7: 3 // right, rightMirrored
        default: 0
        }
    }

    /// Converts a point given as fractions of the upright picture into
    /// fractions of the portrait screen.
    static func portraitFraction(x: Double, y: Double, quarterTurns: Int) -> (x: Double, y: Double) {
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: (y, 1 - x)
        case 2: (1 - x, 1 - y)
        case 3: (1 - y, x)
        default: (x, y)
        }
    }
}

/// Accumulates bytes from a stream connection and yields whole messages.
struct TetherMessageReader {
    private var buffer = Data()

    enum ReadError: Error { case oversizedMessage }

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func next() throws -> (TetherMessageType?, Data)? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard length >= 1, length <= TetherWire.maxMessageSize else { throw ReadError.oversizedMessage }
        guard buffer.count >= 4 + length else { return nil }
        // Data slices keep their parent's indices, so always offset from startIndex.
        let typeIndex = buffer.index(buffer.startIndex, offsetBy: 4)
        let end = buffer.index(typeIndex, offsetBy: length)
        let type = TetherMessageType(rawValue: buffer[typeIndex])
        let payload = Data(buffer[buffer.index(after: typeIndex)..<end])
        buffer = Data(buffer[end...])
        return (type, payload)
    }
}

struct ByteReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = Data(data)
    }

    mutating func read(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    mutating func readUInt8() -> UInt8? {
        read(1)?.first
    }

    mutating func readUInt16() -> UInt16? {
        read(2).map { $0.reduce(0) { ($0 << 8) | UInt16($1) } }
    }

    mutating func readUInt64() -> UInt64? {
        read(8).map { $0.reduce(0) { ($0 << 8) | UInt64($1) } }
    }

    func remaining() -> Data {
        data.subdata(in: offset..<data.count)
    }
}

extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
