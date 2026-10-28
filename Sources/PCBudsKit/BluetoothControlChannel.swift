import Foundation

/// Failure of one noise-control round trip.
public enum ControlError: Error, Equatable, Sendable {
    /// The paired earbuds are not connected right now.
    case notConnected
    /// The system refused Bluetooth access; the user has to allow it in System Settings.
    case permissionDenied
    /// The earbuds are connected but not a family this build can control.
    case unsupportedDevice
    /// The control channel could not be opened.
    case openFailed
    /// The buds accepted the command but never answered.
    case noReply
    /// The buds answered with a non-zero status.
    case rejected
    /// The control channel closed mid-command.
    case closed
}

/// The classic-Bluetooth RFCOMM link to the paired earbuds.
///
/// Discovery is lazy: nothing touches IOBluetooth until the first command, so a user who
/// never presses F5 never sees a Bluetooth prompt. If access is refused, the command fails
/// silently and the next command tries again — there is no polling and no retry loop.
///
/// Must be used from the main thread; completions arrive on the main thread.
@MainActor
public final class BluetoothControlChannel: NSObject, @unchecked Sendable {
    public static let shared = BluetoothControlChannel()

    /// Called with every noise-mode report the buds send, solicited or not.
    public var onState: ((NoiseState) -> Void)?

    /// Whether the paired earbuds are reachable. Cheap: it uses the connection state from
    /// the last command and never performs I/O, so it cannot trigger a permission prompt.
    public var isDeviceReachable: Bool { transport.isReachable }

    /// Whether the last Bluetooth operation was refused by the system permission gate.
    public var permissionDenied: Bool { transport.permissionDenied }

    /// Family-specific encoding of the earbuds.
    public var profile: NoiseProfile { NoiseProfile(deviceName: transport.deviceName) }

    /// The last mode confirmed by the buds, if a report is still recent enough to trust.
    public var lastState: NoiseState? {
        guard let cached = cachedState,
              Date().timeIntervalSince(cached.date) < Self.stateLifetime
        else { return nil }
        return cached.state
    }

    /// Reads the current noise mode from the buds.
    public func readNoiseState(
        completion: @escaping @MainActor (Result<NoiseState, ControlError>) -> Void
    ) {
        let profile = profile
        transport.perform(
            expected: (OPPCommand.read, OPPCommand.readReply),
            timeout: Self.replyTimeout,
            request: { sequence in OPPMessage.readNoise(sequence: sequence) },
            parse: { reply in OPPMessage.parseReadReply(reply.payload, profile: profile) },
            completion: { [weak self] result in
                if case .success(let state) = result { self?.publish(state) }
                completion(result)
            }
        )
    }

    /// Switches the buds to `query.mode` and waits for the SET acknowledgement.
    public func setNoiseMode(
        _ query: NoiseQuery,
        completion: @escaping @MainActor (Result<NoiseState, ControlError>) -> Void
    ) {
        let profile = profile
        guard let value = profile.writeValue(for: query, preferring: lastState) else {
            completion(.failure(.unsupportedDevice))
            return
        }
        let level = query.mode == .anc ? lastState?.level : nil
        transport.perform(
            expected: (OPPCommand.set, OPPCommand.setAck),
            timeout: Self.replyTimeout,
            mismatchError: .rejected,
            request: { sequence in
                OPPMessage.setNoiseMode(value, bytes: profile.modeValueByteCount, sequence: sequence)
            },
            parse: { reply in
                guard let status = OPPMessage.ackStatus(reply.payload), status == 0 else {
                    return nil
                }
                return NoiseState(mode: query.mode, level: level)
            },
            completion: { [weak self] result in
                if case .success(let state) = result { self?.publish(state) }
                completion(result)
            }
        )
    }

    // MARK: - State cache

    static let stateLifetime: TimeInterval = 120
    static let replyTimeout: TimeInterval = 4

    private var cachedState: (state: NoiseState, date: Date)?

    /// Records a report, whether it answers a command or arrives unsolicited.
    func publish(_ state: NoiseState) {
        cachedState = (state, Date())
        onState?(state)
    }

    private let transport = BluetoothTransport()
}
