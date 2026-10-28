import Foundation

/// Builders and parsers for the three noise-control messages, kept free of I/O so they can
/// be checked against captured traffic without hardware.
///
/// Status and read payloads share one shape: `<topic> <count> (<id> <value…>)…`. Noise
/// mode is topic `0x03`, entry `0x01`; the value is one or two bytes depending on the
/// family.
public enum OPPMessage {
    /// Parses `<topic> <count> (<id> <value…>)…` from a status or read payload.
    ///
    /// Returns `nil` when the payload is truncated, has a trailing remainder or repeats an
    /// entry id — all signs of a different message, not of a partial one.
    public static func noiseEntries(
        in payload: [UInt8],
        topic: UInt8 = OPPCommand.topicNoise
    ) -> [(id: UInt8, value: [UInt8])]? {
        guard payload.count >= 2, payload[0] == topic else { return nil }
        let count = Int(payload[1])
        var entries: [(id: UInt8, value: [UInt8])] = []
        var index = 2
        // A single noise mode is always the last entry; everything after its id is its
        // value, whose width only the family knows.
        while index < payload.count {
            let id = payload[index]
            index += 1
            let remaining = payload.count - index
            let take = entries.count == count - 1 ? remaining : min(remaining, 1)
            guard take > 0 else { return nil }
            entries.append((id, Array(payload[index..<index + take])))
            index += take
        }
        guard entries.count == count, Set(entries.map(\.id)).count == entries.count else {
            return nil
        }
        return entries
    }

    /// Decodes the noise-mode value out of a status report or read reply.
    public static func parseNoise(_ frame: OPPFrame, profile: NoiseProfile) -> NoiseState? {
        guard let value = noiseValue(in: frame.payload, profile: profile) else { return nil }
        return profile.decode(value: value)
    }

    /// Decodes the noise-mode value out of a read reply `<status> <count> <id> <value…>`.
    public static func parseReadReply(_ payload: [UInt8], profile: NoiseProfile) -> NoiseState? {
        guard payload.count >= 4, payload[0] == 0, payload[1] == 1,
              payload[2] == OPPCommand.noiseEntryID
        else { return nil }
        let width = profile.modeValueByteCount
        guard width > 0, payload.count == 3 + width else { return nil }
        return profile.decode(value: littleEndian(payload[3...]))
    }

    /// Decodes the noise-mode value out of a complete status-report frame.
    public static func parseReportFrame(_ bytes: [UInt8], profile: NoiseProfile) -> NoiseState? {
        let (result, _) = OPPFrame.decode(bytes)
        guard case .frame(let frame) = result else { return nil }
        return parseNoise(frame, profile: profile)
    }

    static func noiseValue(in payload: [UInt8], profile: NoiseProfile) -> UInt16? {
        let width = profile.modeValueByteCount
        guard width > 0, let entries = noiseEntries(in: payload),
              entries.count == 1,
              let entry = entries.first,
              entry.id == OPPCommand.noiseEntryID,
              entry.value.count == width
        else { return nil }
        return littleEndian(entry.value[...])
    }

    static func littleEndian(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        var value: UInt16 = 0
        for (shift, byte) in bytes.enumerated() {
            value |= UInt16(byte) << (8 * UInt16(shift))
        }
        return value
    }

    // MARK: - Builders

    /// Frame that switches the buds to `value` (`0x04 0x04`, payload `[01 01 value…]`).
    ///
    /// The value is always sent at the family's full width: the convenience byte forms are
    /// rewritten by the firmware and must not be used.
    public static func setNoiseMode(
        _ value: UInt16, bytes width: Int, sequence: UInt8
    ) -> OPPFrame? {
        guard width == 1 || width == 2 else { return nil }
        if width == 1, value > 0xFF { return nil }
        var payload: [UInt8] = [OPPCommand.noiseEntryID, OPPCommand.noiseEntryID, UInt8(value & 0xFF)]
        if width == 2 { payload.append(UInt8(value >> 8)) }
        return OPPFrame(command: OPPCommand.set, messageType: OPPCommand.set, sequence: sequence,
                        payload: payload)
    }

    /// Frame that asks for the current noise mode (`0x0C 0x01`, payload `[01 01]`).
    public static func readNoise(sequence: UInt8) -> OPPFrame {
        OPPFrame(command: OPPCommand.read, messageType: OPPCommand.readQuery, sequence: sequence,
                 payload: [OPPCommand.noiseEntryID, OPPCommand.noiseEntryID])
    }

    /// Frame that greets the buds before the first command (`0x00 0x01`, empty payload).
    public static func hello(sequence: UInt8) -> OPPFrame {
        OPPFrame(command: OPPCommand.system, messageType: OPPCommand.hello, sequence: sequence)
    }

    /// Status byte of a SET acknowledgement. `nil` when the payload has no status field,
    /// which is always a failure.
    public static func ackStatus(_ payload: [UInt8]) -> UInt8? {
        guard let first = payload.first else { return nil }
        return first
    }
}
