import Foundation

/// Wire encodings for the two earbud families PCBuds supports.
///
/// The families differ in the width of the noise-mode value and in which bit patterns
/// mean what. Treating them as one profile silently writes the wrong mode, so the profile
/// is resolved once per connection from the SDP record or the advertised device name.
public enum NoiseProfile: Sendable, Equatable {
    /// OPPO Enco Air5 Pro / Enco Free4 — two-byte value.
    case air5Pro
    /// realme Buds T500 Pro and the OnePlus Buds generation — one-byte value.
    case t500Pro
    /// Paired, but not a model this build knows how to control.
    case unsupported

    // MARK: - Discovery from names

    public init(deviceName: String?) {
        let key = NoiseProfile.normalize(deviceName)
        guard !key.isEmpty else {
            self = .unsupported
            return
        }
        if ["encoair5pro", "oppoencoair5pro", "encofree4", "oppoencofree4"].contains(key) {
            self = .air5Pro
        } else if ["budst500pro", "realmebudst500pro", "realmet500pro"].contains(key) {
            self = .t500Pro
        } else {
            self = .unsupported
        }
    }

    /// Lowercased, letters-and-digits-only form of a device name.
    static func normalize(_ name: String?) -> String {
        (name ?? "")
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    // MARK: - Shape

    /// Number of bytes carrying a noise-mode value in a report. `0` = not controllable.
    public var modeValueByteCount: Int {
        switch self {
        case .air5Pro: 2
        case .t500Pro: 1
        case .unsupported: 0
        }
    }

    // MARK: - Off / Transparency

    /// The value written when switching to Off.
    public var offValue: UInt16? {
        switch self {
        case .air5Pro: 0x0008
        case .t500Pro: 0x01
        case .unsupported: nil
        }
    }

    /// The value written when switching to Transparency.
    ///
    /// The Air5 family only accepts the fixed-transparency child value `0x0100`; the
    /// convenience value `0x0004` is rewritten by the firmware to adaptive transparency.
    public var transparencyValue: UInt16? {
        switch self {
        case .air5Pro: 0x0100
        case .t500Pro: 0x02
        case .unsupported: nil
        }
    }

    /// The ANC value written when the reported strength is unknown or unsupported.
    public var defaultANCValue: UInt16? {
        switch self {
        case .air5Pro: 0x0010
        case .t500Pro: 0x08
        case .unsupported: nil
        }
    }

    // MARK: - ANC levels

    /// Wire value for a specific ANC strength.
    public func ancValue(for level: AncLevel) -> UInt16? {
        switch (self, level) {
        case (.air5Pro, .max): 0x0010
        case (.air5Pro, .moderate): 0x0020
        case (.air5Pro, .mild): 0x0040
        case (.air5Pro, .smart): 0x0080
        case (.t500Pro, .mild): 0x04
        case (.t500Pro, .max): 0x08
        case (.t500Pro, .moderate): 0x10
        case (.t500Pro, .smart): 0x20
        case (.unsupported, _): nil
        }
    }

    /// Decodes a value reported by the buds.
    ///
    /// The convenience values `0x01` / `0x02` / `0x04` are not treated as mode values for
    /// the Air5 family: the firmware normalises them, and they never arrive as the result
    /// of a completed switch.
    public func decode(value: UInt16) -> NoiseState? {
        switch self {
        case .air5Pro:
            switch value {
            case 0x0008: NoiseState(mode: .off)
            case 0x0100: NoiseState(mode: .transparency)
            case 0x0010: NoiseState(mode: .anc, level: .max)
            case 0x0020: NoiseState(mode: .anc, level: .moderate)
            case 0x0040: NoiseState(mode: .anc, level: .mild)
            case 0x0080: NoiseState(mode: .anc, level: .smart)
            default: nil
            }
        case .t500Pro:
            switch value {
            case 0x01: NoiseState(mode: .off)
            case 0x02: NoiseState(mode: .transparency)
            case 0x04: NoiseState(mode: .anc, level: .mild)
            case 0x08: NoiseState(mode: .anc, level: .max)
            case 0x10: NoiseState(mode: .anc, level: .moderate)
            case 0x20: NoiseState(mode: .anc, level: .smart)
            default: nil
            }
        case .unsupported:
            nil
        }
    }

    /// Whether a value reported by the buds selects the same mode as `query`.
    ///
    /// An ANC strength is intentionally *not* part of the comparison: cycling into ANC
    /// must count as success whichever strength the buds were already in.
    public func matches(_ reported: UInt16, _ query: NoiseQuery) -> Bool {
        guard let state = decode(value: reported) else { return false }
        return state.mode == query.mode
    }

    /// Builds the value to write for `query` given the mode most recently observed.
    ///
    /// The strength the buds were last seen in is kept when switching back into ANC, so a
    /// user who picked "mild" once does not silently get "max" on the next F5 press.
    public func writeValue(for query: NoiseQuery, preferring reports: NoiseState?) -> UInt16? {
        switch query.mode {
        case .off: return offValue
        case .transparency: return transparencyValue
        case .anc:
            if let level = reports?.level, let value = ancValue(for: level) {
                return value
            }
            return defaultANCValue
        }
    }

    /// Converts a direction into a concrete next mode given the current one.
    public func query(from state: NoiseState, direction: NoiseDirection) -> NoiseQuery {
        switch direction {
        case .cycle:
            return NoiseQuery(mode: state.mode.next)
        case .set(let mode):
            return NoiseQuery(mode: mode)
        }
    }
}

/// What the user asked for when pressing F5.
public struct NoiseQuery: Sendable, Equatable {
    public var mode: NoiseMode

    public init(mode: NoiseMode) {
        self.mode = mode
    }
}

/// Cycle (F5) or jump straight to a mode (menu item).
public enum NoiseDirection: Sendable, Equatable {
    case cycle
    case set(NoiseMode)
}
