import Foundation

/// A complete frame on the earbud control channel.
public struct OPPFrame: Equatable, Sendable {
    /// Command byte, e.g. `0x04`.
    public var command: UInt8
    /// Message-type byte, e.g. `0x02` for a status notification.
    public var messageType: UInt8
    public var sequence: UInt8
    public var payload: [UInt8]

    public init(command: UInt8, messageType: UInt8, sequence: UInt8, payload: [UInt8] = []) {
        self.command = command
        self.messageType = messageType
        self.sequence = sequence
        self.payload = payload
    }

    /// Bytes on the wire for this frame.
    public var encoded: [UInt8] {
        OPPFrame.encode(command: command, messageType: messageType,
                        sequence: sequence, payload: payload)
    }

    public static let sync: UInt8 = 0xAA
    /// Two reserved zero bytes follow the length.
    static let reserved: [UInt8] = [0x00, 0x00]
    /// Two reserved bytes + `command`, `messageType`, `sequence`, `payloadLength` (2 bytes).
    /// `len` counts exactly these plus the payload: `len = 7 + payload.count`.
    static let headerSize = 7

    // MARK: - Encoding

    /// Builds a frame: `AA len 00 00 cmd type seq plen(2, LE) payload`.
    ///
    /// `len` is an unsigned LEB128 integer counting every byte after itself. A payload
    /// larger than the one- and two-byte lengths can describe is refused rather than
    /// silently truncated.
    public static func encode(
        command: UInt8, messageType: UInt8, sequence: UInt8, payload: [UInt8]
    ) -> [UInt8] {
        let bodyLength = headerSize + payload.count
        guard payload.count <= 0x3FFF, bodyLength <= 0x3FFF else { return [] }
        var frame: [UInt8] = [sync]
        frame.append(contentsOf: LEB128.encode(UInt32(bodyLength)))
        frame.append(contentsOf: reserved)
        frame.append(command)
        frame.append(messageType)
        frame.append(sequence)
        frame.append(UInt8(payload.count & 0xFF))
        frame.append(UInt8(payload.count >> 8))
        frame.append(contentsOf: payload)
        return frame
    }

    // MARK: - Decoding

    public enum DecodeResult: Equatable, Sendable {
        case frame(OPPFrame)
        /// Not enough bytes yet; the buffer is left untouched.
        case incomplete
        /// The next sync byte was skipped to resynchronise.
        case skipped(Int)
    }

    /// Decodes the frame at the head of `buffer`, or reports why it cannot be used yet.
    ///
    /// The caller removes `consumed` bytes: the whole frame on success, the junk prefix on
    /// `.skipped`. Two length fields must agree byte for byte; a mismatch is treated as
    /// misaligned data, exactly as a truncated frame is.
    public static func decode(_ buffer: [UInt8]) -> (result: DecodeResult, consumed: Int) {
        guard let start = buffer.firstIndex(of: sync) else {
            return (.incomplete, buffer.count)
        }
        if start > 0 { return (.skipped(start), start) }

        guard let (bodyLength, lengthBytes) = LEB128.decode(buffer, from: 1) else {
            // A length that runs out of bytes, or a multi-byte length that keeps growing,
            // means this sync byte is not a frame boundary.
            return buffer.count <= 3 ? (.incomplete, 0) : (.skipped(1), 1)
        }
        let bodyStart = 1 + lengthBytes
        guard bodyLength >= UInt32(headerSize) else { return (.skipped(1), 1) }
        let total = bodyStart + Int(bodyLength)
        guard buffer.count >= total else { return (.incomplete, 0) }

        // bodyStart indexes the first reserved byte:
        // +0 +1 reserved, +2 command, +3 messageType, +4 sequence, +5 +6 payload length.
        guard bodyStart + headerSize <= buffer.count else { return (.skipped(1), 1) }
        guard buffer[bodyStart] == 0, buffer[bodyStart + 1] == 0 else {
            return (.skipped(1), 1)
        }
        let payloadLength = Int(buffer[bodyStart + 5]) | Int(buffer[bodyStart + 6]) << 8
        guard headerSize + payloadLength == Int(bodyLength) else {
            return (.skipped(1), 1)
        }

        let frame = OPPFrame(
            command: buffer[bodyStart + 2],
            messageType: buffer[bodyStart + 3],
            sequence: buffer[bodyStart + 4],
            payload: Array(buffer[(bodyStart + headerSize)..<total])
        )
        return (.frame(frame), total)
    }
}

/// Unsigned LEB128, as used for the frame length.
enum LEB128 {
    /// At most three bytes, matching the two length fields the protocol can describe.
    static let maxBytes = 3

    static func encode(_ value: UInt32) -> [UInt8] {
        guard value <= 0x3FFF else { return [] }
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value != 0
        return bytes
    }

    /// Decodes the LEB128 integer starting at `offset`.
    /// Returns `nil` when the buffer ends first or the value needs more than `maxBytes`.
    static func decode(_ buffer: [UInt8], from offset: Int) -> (value: UInt32, byteCount: Int)? {
        var result: UInt32 = 0
        var shift: UInt32 = 0
        var index = offset
        for _ in 0..<maxBytes {
            guard index < buffer.count else { return nil }
            let byte = buffer[index]
            result |= UInt32(byte & 0x7F) << shift
            index += 1
            if byte & 0x80 == 0 { return (result, index - offset) }
            shift += 7
        }
        return nil
    }
}

/// Reassembles frames from the arbitrary chunks RFCOMM delivers.
public struct OPPFrameReader: Sendable {
    private var buffer: [UInt8] = []

    public init() {}

    /// Bytes buffered but not yet forming a frame; for DEBUG diagnostics only.
    public var bufferedByteCount: Int { buffer.count }

    /// Appends a chunk and returns every frame it completed, in order.
    public mutating func append(_ chunk: [UInt8]) -> [OPPFrame] {
        buffer.append(contentsOf: chunk)
        var frames: [OPPFrame] = []
        while true {
            let (result, consumed) = OPPFrame.decode(buffer)
            switch result {
            case .incomplete:
                return frames
            case .skipped:
                buffer.removeFirst(consumed)
            case .frame(let frame):
                frames.append(frame)
                buffer.removeFirst(consumed)
            }
            if buffer.isEmpty { return frames }
        }
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }
}
