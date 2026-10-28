import Testing
@testable import PCBudsKit

/// Frame layout, resynchronisation and stream reassembly against captured traffic.
struct OPPFrameTests {
    @Test func encodesHelloExactly() {
        let frame = OPPMessage.hello(sequence: 0xF0)
        #expect(frame.encoded == [0xAA, 0x07, 0x00, 0x00, 0x00, 0x01, 0xF0, 0x00, 0x00])
    }

    @Test func encodesReadQueryExactly() {
        let frame = OPPMessage.readNoise(sequence: 0xF1)
        #expect(frame.encoded == [
            0xAA, 0x09, 0x00, 0x00, 0x0C, 0x01, 0xF1, 0x02, 0x00, 0x01, 0x01,
        ])
    }

    @Test func encodesAir5SetWithTwoByteValue() throws {
        let frame = try #require(OPPMessage.setNoiseMode(0x0100, bytes: 2, sequence: 0xF2))
        #expect(frame.encoded == [
            0xAA, 0x0B, 0x00, 0x00, 0x04, 0x04, 0xF2, 0x04, 0x00, 0x01, 0x01, 0x00, 0x01,
        ])
    }

    @Test func encodesT500SetWithOneByteValue() throws {
        let frame = try #require(OPPMessage.setNoiseMode(0x08, bytes: 1, sequence: 0xF2))
        #expect(frame.encoded == [
            0xAA, 0x0A, 0x00, 0x00, 0x04, 0x04, 0xF2, 0x03, 0x00, 0x01, 0x01, 0x08,
        ])
    }

    @Test func setNoiseModeRejectsImpossibleWidths() {
        #expect(OPPMessage.setNoiseMode(0x08, bytes: 0, sequence: 0) == nil)
        #expect(OPPMessage.setNoiseMode(0x08, bytes: 3, sequence: 0) == nil)
        #expect(OPPMessage.setNoiseMode(0x0100, bytes: 1, sequence: 0) == nil)
    }

    @Test func leb128RoundTrips() throws {
        for value: UInt32 in [0, 1, 7, 127, 128, 200, 300, 0x3FFF] {
            let bytes = LEB128.encode(value)
            let decoded = try #require(LEB128.decode(bytes, from: 0))
            #expect(decoded.value == value)
            #expect(decoded.byteCount == bytes.count)
        }
    }

    @Test func leb128RefusesOversizedValues() {
        #expect(LEB128.encode(0x4000).isEmpty)
        #expect(LEB128.decode([0x80, 0x80, 0x80, 0x01], from: 0) == nil)
    }

    @Test func decodesCapturedAir5Report() throws {
        let bytes = Fixture.bytes("report-air5-off")
        let (result, consumed) = OPPFrame.decode(bytes)
        guard case .frame(let frame) = result else {
            Issue.record("expected one decoded frame")
            return
        }
        #expect(consumed == bytes.count)
        #expect(frame.command == OPPCommand.status)
        #expect(frame.messageType == OPPCommand.statusReport)
        #expect(frame.sequence == 0x67)
        #expect(frame.payload == [0x03, 0x01, 0x01, 0x08, 0x00])
        #expect(frame.encoded == bytes)
    }

    @Test func capturedAckAndReadReplyDecode() {
        // The lead supplied the ACK as "cmd 0x04 msgType 0x84 payload [00]"; this is that
        // acknowledgement in the on-wire frame format (`len` = 7 + 1).
        let ack: [UInt8] = [0xAA, 0x08, 0x00, 0x00, 0x04, 0x84, 0xF0, 0x01, 0x00, 0x00]
        let (ackResult, ackConsumed) = OPPFrame.decode(ack)
        guard case .frame(let ackFrame) = ackResult else {
            Issue.record("expected the captured SET ACK to decode")
            return
        }
        #expect(ackConsumed == ack.count)
        #expect(ackFrame.command == OPPCommand.set)
        #expect(ackFrame.messageType == OPPCommand.setAck)
        #expect(ackFrame.sequence == 0xF0)
        #expect(ackFrame.payload == [0x00])

        let reply = Fixture.bytes("read-reply-air5-off")
        let (replyResult, replyConsumed) = OPPFrame.decode(reply)
        guard case .frame(let replyFrame) = replyResult else {
            Issue.record("expected the captured read reply to decode")
            return
        }
        #expect(replyConsumed == reply.count)
        #expect(replyFrame.command == OPPCommand.read)
        #expect(replyFrame.messageType == OPPCommand.readReply)
        #expect(replyFrame.payload == [0x00, 0x01, 0x01, 0x08, 0x00])
    }

    @Test func incompleteFrameKeepsBuffer() {
        let bytes = Fixture.bytes("report-air5-off")
        let (result, consumed) = OPPFrame.decode(Array(bytes.dropLast(3)))
        #expect(result == .incomplete)
        #expect(consumed == 0)
    }

    @Test func leadingGarbageIsSkipped() {
        let garbage: [UInt8] = [0x11, 0x22, 0x33]
        let bytes = garbage + Fixture.bytes("report-air5-off")
        let (result, consumed) = OPPFrame.decode(bytes)
        #expect(result == .skipped(3))
        #expect(consumed == 3)
    }

    @Test func disagreeingLengthFieldsResynchronise() throws {
        var bytes = Fixture.bytes("report-air5-off")
        // Layout with a one-byte LEN: aa | len | 00 00 | cmd | type | seq | plenLo plenHi | payload
        bytes[8] = 0x04  // the two length fields no longer agree
        let (result, consumed) = OPPFrame.decode(bytes)
        #expect(result == .skipped(1))
        #expect(consumed == 1)
    }

    @Test func garbageReservedBytesResynchronise() {
        var bytes = Fixture.bytes("report-air5-off")
        bytes[2] = 0xFF  // the reserved 00 00 bytes are not zero
        let (result, consumed) = OPPFrame.decode(bytes)
        #expect(result == .skipped(1))
        #expect(consumed == 1)
    }

    @Test func truncatedLEB128IsIncomplete() {
        // `aa 8c` promises a continuation byte that never arrives.
        let (result, consumed) = OPPFrame.decode([0xAA, 0x8C])
        #expect(result == .incomplete)
        #expect(consumed == 0)
    }

    @Test func oversizedLEB128Resynchronises() {
        // Four continuation bytes exceed the three-byte length the protocol allows.
        let (result, consumed) = OPPFrame.decode([0xAA, 0x80, 0x80, 0x80, 0x01, 0x00])
        #expect(result == .skipped(1))
        #expect(consumed == 1)
    }

    @Test func twoByteLengthForLargePayload() {
        // A 200-byte payload needs len = 207 = 0xCF 0x01 in LEB128.
        let payload = [UInt8](repeating: 0x5A, count: 200)
        let encoded = OPPFrame.encode(command: 0x0C, messageType: 0x01, sequence: 0xF0, payload: payload)
        // sync + 2-byte LEN + two reserved + cmd/type/seq + plen(2) + payload
        #expect(encoded.count == 1 + 2 + 2 + 3 + 2 + 200)
        #expect(Array(encoded[0..<4]) == [0xAA, 0xCF, 0x01, 0x00])
        let (result, consumed) = OPPFrame.decode(encoded)
        guard case .frame(let frame) = result else {
            Issue.record("expected a frame with a two-byte length")
            return
        }
        #expect(consumed == encoded.count)
        #expect(frame.payload == payload)
    }

    @Test func readerReassemblesFramesSplitAcrossReads() {
        let bytes = Fixture.bytes("report-air5-transparent")
        var reader = OPPFrameReader()
        var frames: [OPPFrame] = []
        for byte in bytes {
            frames += reader.append([byte])
        }
        #expect(frames.count == 1)
        #expect(frames.first?.sequence == 0x67)
        #expect(reader.bufferedByteCount == 0)
    }

    @Test func readerSplitsCoalescedFrames() {
        var stream = Fixture.bytes("report-air5-off")
        stream += Fixture.bytes("report-air5-smart")
        stream += Fixture.bytes("report-battery")
        var reader = OPPFrameReader()
        let frames = reader.append(stream)
        #expect(frames.map(\.sequence) == [0x67, 0x60, 0x0C])
        #expect(reader.bufferedByteCount == 0)
    }

    @Test func readerKeepsPartialTail() {
        var stream = Fixture.bytes("report-air5-off")
        let tail = Fixture.bytes("report-air5-smart")
        stream += tail.prefix(5)
        var reader = OPPFrameReader()
        let first = reader.append(stream)
        #expect(first.count == 1)
        #expect(reader.bufferedByteCount == 5)
        let second = reader.append(Array(tail.dropFirst(5)))
        #expect(second.count == 1)
        #expect(second.first?.sequence == 0x60)
    }

    @Test func readerRecoversAfterGarbage() {
        var reader = OPPFrameReader()
        let frames = reader.append([0xAA, 0x02, 0xFF] + Fixture.bytes("report-t500-off"))
        #expect(frames.count == 1)
        #expect(frames.first?.payload == [0x03, 0x01, 0x01, 0x01])
    }
}
