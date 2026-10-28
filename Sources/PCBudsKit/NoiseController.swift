import Foundation

/// Owns the noise-mode switch. One instance per process; the app calls `cycle()` from the
/// F5 handler and the menu.
///
/// Every method is fire-and-forget: a missing earbud, a refused Bluetooth permission or a
/// transport error all end the same way — nothing happens, and nothing is logged in
/// release builds.
///
/// Must be used from the main thread; all callbacks arrive on the main thread.
@MainActor
public final class NoiseController: @unchecked Sendable {
    public static let shared = NoiseController()

    /// Called at most once per launch, the first time Bluetooth access is refused.
    public var onPermissionNeeded: (() -> Void)?

    /// Notified after a switch round-trips successfully. DEBUG diagnostics only.
    public var onModeChanged: ((NoiseMode) -> Void)?

    private let channel: BluetoothControlChannel
    private var lastRequestAt: Date?
    private var permissionReported = false
    private var lastState: NoiseState?
    private var lastStateDate: Date?

    public init() {
        channel = .shared
        channel.onState = { [weak self] state in
            self?.observe(state)
        }
    }

    /// Whether the paired earbuds look connected. Cheap and side-effect free.
    public var isDeviceConnected: Bool { channel.isDeviceReachable }

    /// The mode most recently confirmed by the buds, if that report is still fresh.
    public func lastKnownMode() -> NoiseMode? { lastKnownState()?.mode }

    /// The whole last-known state, including ANC strength, for menu titles.
    public func lastKnownState() -> NoiseState? {
        guard let lastStateDate,
              Date().timeIntervalSince(lastStateDate) < BluetoothControlChannel.stateLifetime
        else { return nil }
        return lastState
    }

    /// Cycles Noise cancellation → Transparency → Off → Noise cancellation.
    public func cycle() {
        request(.cycle)
    }

    /// Jumps straight to one mode (menu items).
    public func set(_ mode: NoiseMode) {
        request(.set(mode))
    }

    // MARK: - Switching

    /// Presses closer together than this count as one.
    static let debounceInterval: TimeInterval = 1.5

    private func request(_ direction: NoiseDirection) {
        let now = Date()
        if let lastRequestAt, now.timeIntervalSince(lastRequestAt) < Self.debounceInterval {
            return
        }
        lastRequestAt = now

        if channel.permissionDenied {
            reportPermissionIfNeeded()
            // Keep trying: the user may have just granted access.
        }
        perform(direction, retryAllowed: true)
    }

    private func perform(_ direction: NoiseDirection, retryAllowed: Bool) {
        channel.readNoiseState { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                if error == .permissionDenied { self.reportPermissionIfNeeded() }
                if retryAllowed, self.channel.isDeviceReachable, error != .unsupportedDevice {
                    // A channel closed under us; one retry, never a loop.
                    self.perform(direction, retryAllowed: false)
                }

            case .success(let current):
                self.observe(current)
                // The buds report the mode they are in; the cycle starts from there, so a
                // mode changed on the phone or by the earbuds themselves is always honoured.
                let query = self.channel.profile.query(from: current, direction: direction)
                self.channel.setNoiseMode(query) { [weak self] result in
                    guard let self else { return }
                    switch result {
                    case .success(let state):
                        self.observe(state)
                        self.notify(state.mode)
                    case .failure(let error):
                        if error == .permissionDenied { self.reportPermissionIfNeeded() }
                    }
                }
            }
        }
    }

    /// Mirrors every confirmed report into the controller so `lastKnownMode()` is fresh
    /// even when the buds announce a change nobody asked for.
    private func observe(_ state: NoiseState) {
        lastState = state
        lastStateDate = Date()
    }

    private func reportPermissionIfNeeded() {
        guard !permissionReported else { return }
        permissionReported = true
        #if DEBUG
        print("PCBuds: Bluetooth access refused; asking the user")
        #endif
        onPermissionNeeded?()
    }

    private func notify(_ mode: NoiseMode) {
        #if DEBUG
        print("PCBuds: noise mode -> \(mode.rawValue)")
        #endif
        onModeChanged?(mode)
    }
}
