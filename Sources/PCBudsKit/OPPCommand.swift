/// Command and message-type bytes of the earbud control protocol.
///
/// A command is addressed as `(command, messageType)`; the reply sets the high bit of the
/// message type (`0x04`/SET becomes `0x84`/SET ACK).
public enum OPPCommand {
    /// Hello / handshake sent once per connection.
    public static let system: UInt8 = 0x00
    public static let hello: UInt8 = 0x01

    /// Status notifications and read queries (`0x04 0x02` reports, `0x04 0x01` queries).
    public static let status: UInt8 = 0x04
    public static let statusQuery: UInt8 = 0x01
    public static let statusReport: UInt8 = 0x02

    /// SET (`0x04 0x04`) and its acknowledgement (`0x04 0x84`).
    public static let set: UInt8 = 0x04
    public static let setAck: UInt8 = 0x84

    /// Noise-mode read(`0x0C 0x01`) and reply (`0x0C 0x81`).
    public static let read: UInt8 = 0x0C
    public static let readQuery: UInt8 = 0x01
    public static let readReply: UInt8 = 0x81

    // MARK: - Status payload topics

    /// Status payload topic byte: battery.
    public static let topicBattery: UInt8 = 0x01
    /// Status payload topic byte: wear / placement.
    public static let topicWear: UInt8 = 0x02
    /// Status payload topic byte: noise mode.
    public static let topicNoise: UInt8 = 0x03

    /// Entry id of the noise mode inside a noise-mode payload.
    public static let noiseEntryID: UInt8 = 0x01
}
