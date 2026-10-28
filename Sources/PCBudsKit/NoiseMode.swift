/// The three states the F5 key cycles through, in cycle order.
public enum NoiseMode: String, Sendable, CaseIterable, Equatable {
    case anc
    case transparency
    case off

    /// Short label used by menus and the mode indicator.
    public var label: String {
        switch self {
        case .anc: "降噪"
        case .transparency: "通透"
        case .off: "关闭"
        }
    }

    /// The next mode in the F5 cycle: Noise cancellation → Transparency → Off → Noise cancellation.
    public var next: NoiseMode {
        switch self {
        case .anc: .transparency
        case .transparency: .off
        case .off: .anc
        }
    }
}

/// Noise levels reported by the earbuds. Only used for display, never for choosing a
/// write value on its own — see `NoiseProfile.ancValue`.
public enum AncLevel: String, Sendable, Equatable {
    case max
    case moderate
    case mild
    case smart
}

/// A decoded noise-mode report.
public struct NoiseState: Sendable, Equatable {
    public var mode: NoiseMode
    /// Known when the buds report an ANC strength; `nil` for Off, Transparency and for
    /// ANC strengths this build does not recognise.
    public var level: AncLevel?

    public init(mode: NoiseMode, level: AncLevel? = nil) {
        self.mode = mode
        self.level = level
    }
}
