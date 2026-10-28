import Testing
@testable import PCBudsKit

/// Per-family wire values, report decoding, SET/ACK and read-back frames.
struct NoiseProtocolTests {
    // MARK: - Profile resolution

    @Test(arguments: [
        ("OPPO Enco Air5 Pro", NoiseProfile.air5Pro),
        ("oppo enco air5 pro", NoiseProfile.air5Pro),
        ("OPPO Enco Free4", NoiseProfile.air5Pro),
        ("realme Buds T500 Pro", NoiseProfile.t500Pro),
        ("OnePlus Buds T500 Pro", NoiseProfile.unsupported),
        ("AirPods Pro", NoiseProfile.unsupported),
        ("", NoiseProfile.unsupported),
        (nil, NoiseProfile.unsupported),
    ] as [(String?, NoiseProfile)])
    func resolvesProfileFromName(name: String?, expected: NoiseProfile) {
        #expect(NoiseProfile(deviceName: name) == expected)
    }

    @Test(arguments: [
        (NoiseProfile.air5Pro, 2),
        (.t500Pro, 1),
        (.unsupported, 0),
    ] as [(NoiseProfile, Int)])
    func valueWidth(profile: NoiseProfile, width: Int) {
        #expect(profile.modeValueByteCount == width)
    }

    // MARK: - Writing

    @Test(arguments: [
        (NoiseMode.off, UInt16(0x0008)),
        (.transparency, UInt16(0x0100)),
        (.anc, UInt16(0x0010)),
    ] as [(NoiseMode, UInt16)])
    func air5WriteValues(mode: NoiseMode, expected: UInt16) {
        let value = NoiseProfile.air5Pro.writeValue(for: NoiseQuery(mode: mode), preferring: nil)
        #expect(value == expected)
    }

    @Test(arguments: [
        (NoiseMode.off, UInt16(0x01)),
        (.transparency, UInt16(0x02)),
        (.anc, UInt16(0x08)),
    ] as [(NoiseMode, UInt16)])
    func t500WriteValues(mode: NoiseMode, expected: UInt16) {
        let value = NoiseProfile.t500Pro.writeValue(for: NoiseQuery(mode: mode), preferring: nil)
        #expect(value == expected)
    }

    @Test func air5NeverSendsConvenienceBytes() {
        // The firmware rewrites 0x01 / 0x02 / 0x04; the Air5 profile must never emit them.
        let forbidden: Set<UInt16> = [0x01, 0x02, 0x04]
        for mode in NoiseMode.allCases {
            #expect(!forbidden.contains(NoiseProfile.air5Pro.writeValue(
                for: NoiseQuery(mode: mode), preferring: nil) ?? 0))
        }
    }

    @Test(arguments: [
        (AncLevel.max, UInt16(0x0010)),
        (.moderate, UInt16(0x0020)),
        (.mild, UInt16(0x0040)),
        (.smart, UInt16(0x0080)),
    ] as [(AncLevel, UInt16)])
    func air5ANCLevels(level: AncLevel, expected: UInt16) {
        #expect(NoiseProfile.air5Pro.ancValue(for: level) == expected)
    }

    @Test(arguments: [
        (AncLevel.mild, UInt16(0x04)),
        (.max, UInt16(0x08)),
        (.moderate, UInt16(0x10)),
        (.smart, UInt16(0x20)),
    ] as [(AncLevel, UInt16)])
    func t500ANCLevels(level: AncLevel, expected: UInt16) {
        #expect(NoiseProfile.t500Pro.ancValue(for: level) == expected)
    }

    @Test func ancKeepsTheLastObservedStrength() {
        let observed = NoiseState(mode: .off)
        // Cycling back into ANC reuses the strength seen before leaving ANC.
        let mild = NoiseProfile.air5Pro.writeValue(
            for: NoiseQuery(mode: .anc),
            preferring: NoiseState(mode: .anc, level: .mild))
        #expect(mild == 0x0040)
        #expect(NoiseProfile.air5Pro.writeValue(for: NoiseQuery(mode: .anc), preferring: observed) == 0x0010)
        #expect(NoiseProfile.t500Pro.writeValue(
            for: NoiseQuery(mode: .anc),
            preferring: NoiseState(mode: .anc, level: .moderate)) == 0x10)
    }

    @Test func unsupportedProfileWritesNothing() {
        for mode in NoiseMode.allCases {
            #expect(NoiseProfile.unsupported.writeValue(
                for: NoiseQuery(mode: mode), preferring: nil) == nil)
        }
    }

    // MARK: - Decoding

    @Test(arguments: [
        (0x0008, NoiseState(mode: .off)),
        (0x0100, NoiseState(mode: .transparency)),
        (0x0010, NoiseState(mode: .anc, level: .max)),
        (0x0020, NoiseState(mode: .anc, level: .moderate)),
        (0x0040, NoiseState(mode: .anc, level: .mild)),
        (0x0080, NoiseState(mode: .anc, level: .smart)),
    ] as [(UInt16, NoiseState)])
    func air5Decode(value: UInt16, expected: NoiseState) {
        #expect(NoiseProfile.air5Pro.decode(value: value) == expected)
    }

    @Test(arguments: [
        (0x01, NoiseState(mode: .off)),
        (0x02, NoiseState(mode: .transparency)),
        (0x04, NoiseState(mode: .anc, level: .mild)),
        (0x08, NoiseState(mode: .anc, level: .max)),
        (0x10, NoiseState(mode: .anc, level: .moderate)),
        (0x20, NoiseState(mode: .anc, level: .smart)),
    ] as [(UInt16, NoiseState)])
    func t500Decode(value: UInt16, expected: NoiseState) {
        #expect(NoiseProfile.t500Pro.decode(value: value) == expected)
    }

    @Test func air5DecodeRejectsForeignValues() {
        #expect(NoiseProfile.air5Pro.decode(value: 0x01) == nil)
        #expect(NoiseProfile.air5Pro.decode(value: 0x0001) == nil)
        #expect(NoiseProfile.air5Pro.decode(value: 0x0800) == nil)
        #expect(NoiseProfile.unsupported.decode(value: 0x08) == nil)
    }

    // MARK: - Cycling

    @Test func cycleOrder() {
        #expect(NoiseMode.anc.next == .transparency)
        #expect(NoiseMode.transparency.next == .off)
        #expect(NoiseMode.off.next == .anc)
    }

    @Test func ancMatchesAnyStrength() {
        let query = NoiseQuery(mode: .anc)
        #expect(NoiseProfile.air5Pro.matches(0x0010, query))
        #expect(NoiseProfile.air5Pro.matches(0x0080, query))
        #expect(NoiseProfile.t500Pro.matches(0x04, query))
        #expect(!NoiseProfile.t500Pro.matches(0x02, query))
    }

    // MARK: - Parsing captured reports

    @Test func decodesCapturedAir5Reports() {
        let profile = NoiseProfile.air5Pro
        let off = OPPMessage.parseReportFrame(Fixture.bytes("report-air5-off"), profile: profile)
        #expect(off == NoiseState(mode: .off))
        let transparent = OPPMessage.parseReportFrame(Fixture.bytes("report-air5-transparent"), profile: profile)
        #expect(transparent == NoiseState(mode: .transparency))
        let smart = OPPMessage.parseReportFrame(Fixture.bytes("report-air5-smart"), profile: profile)
        #expect(smart == NoiseState(mode: .anc, level: .smart))
    }

    @Test func decodesCapturedT500Report() {
        let off = OPPMessage.parseReportFrame(Fixture.bytes("report-t500-off"), profile: .t500Pro)
        #expect(off == NoiseState(mode: .off))
    }

    @Test func ignoringNonNoiseTopics() {
        let battery = OPPMessage.parseReportFrame(Fixture.bytes("report-battery"), profile: .air5Pro)
        #expect(battery == nil)
    }

    @Test func reportForWrongFamilyIsIgnored() {
        // A one-byte T500 report cannot be decoded as an Air5 two-byte value.
        #expect(OPPMessage.parseReportFrame(Fixture.bytes("report-t500-off"), profile: .air5Pro) == nil)
        // And the Air5 report's two-byte value is not a valid T500 value.
        #expect(OPPMessage.parseReportFrame(Fixture.bytes("report-air5-off"), profile: .t500Pro) == nil)
    }

    @Test func smartLevelCouplingReportIsIgnored() {
        // While "smart" runs, the buds emit a four-entry block; it is not a mode report.
        let payload: [UInt8] = [0x03, 0x04, 0x01, 0x01]
        #expect(OPPMessage.noiseEntries(in: payload) == nil)
    }

    // MARK: - ACK and read-back

    @Test func setAckStatus() throws {
        let bytes: [UInt8] = [0xAA, 0x08, 0x00, 0x00, 0x04, 0x84, 0xF0, 0x01, 0x00, 0x00]
        let (result, _) = OPPFrame.decode(bytes)
        guard case .frame(let frame) = result else {
            Issue.record("expected one decoded frame")
            return
        }
        #expect(frame.command == OPPCommand.set)
        #expect(frame.messageType == OPPCommand.setAck)
        #expect(frame.payload == [0x00])
        #expect(OPPMessage.ackStatus(frame.payload) == 0)
    }

    @Test func ackWithoutStatusIsFailure() {
        #expect(OPPMessage.ackStatus([]) == nil)
        #expect(OPPMessage.ackStatus([0x01]) == 0x01)
    }

    @Test(arguments: [
        ([UInt8]([0x00, 0x01, 0x01, 0x08, 0x00]), NoiseState(mode: .off)),
        ([0x00, 0x01, 0x01, 0x00, 0x01], NoiseState(mode: .transparency)),
        ([0x00, 0x01, 0x01, 0x10, 0x00], NoiseState(mode: .anc, level: .max)),
    ] as [([UInt8], NoiseState?)])
    func readBackReply(payload: [UInt8], expected: NoiseState?) {
        #expect(OPPMessage.parseReadReply(payload, profile: .air5Pro) == expected)
    }

    @Test func readBackRejectsMalformedReplies() {
        #expect(OPPMessage.parseReadReply([0x01, 0x01, 0x01, 0x08, 0x00], profile: .air5Pro) == nil)
        #expect(OPPMessage.parseReadReply([0x00, 0x01, 0x02, 0x08, 0x00], profile: .air5Pro) == nil)
        #expect(OPPMessage.parseReadReply([0x00, 0x01, 0x01, 0x08], profile: .air5Pro) == nil)
        #expect(OPPMessage.parseReadReply([0x00, 0x01, 0x01, 0x08, 0x00, 0x00], profile: .air5Pro) == nil)
        #expect(OPPMessage.parseReadReply([0x00, 0x01, 0x01, 0x08, 0x00], profile: .unsupported) == nil)
    }

    @Test func decodesCapturedReadReply() {
        let bytes = Fixture.bytes("read-reply-air5-off")
        let (result, _) = OPPFrame.decode(bytes)
        guard case .frame(let frame) = result else {
            Issue.record("expected a frame")
            return
        }
        #expect(frame.command == OPPCommand.read)
        #expect(frame.messageType == OPPCommand.readReply)
        #expect(OPPMessage.parseReadReply(frame.payload, profile: .air5Pro) == NoiseState(mode: .off))
    }

    @Test func labelsAreLocalised() {
        #expect(NoiseMode.anc.label == "降噪")
        #expect(NoiseMode.transparency.label == "通透")
        #expect(NoiseMode.off.label == "关闭")
    }
}
