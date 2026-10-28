import Foundation
import IOBluetooth

/// Owns the IOBluetooth RFCOMM channel: finds the paired earbuds, opens the control
/// channel, keeps it warm between commands and drives one request/reply at a time.
///
/// Main thread only.
@MainActor
final class BluetoothTransport: NSObject {
    /// `0000079A-D102-11E1-9B23-00025B00A5A5`, the control service in the buds' SDP record.
    static let serviceUUIDBytes: [UInt8] = [
        0x00, 0x00, 0x07, 0x9A, 0xD1, 0x02, 0x11, 0xE1,
        0x9B, 0x23, 0x00, 0x02, 0x5B, 0x00, 0xA5, 0xA5,
    ]

    /// How long a connection observation stays usable for `isReachable`.
    static let reachabilityLifetime: TimeInterval = 2
    /// How long the RFCOMM channel may take to open.
    static let openTimeout: TimeInterval = 5
    /// Idle channels are closed after this long to keep the app light.
    static let idleTimeout: TimeInterval = 60

    /// `kIOReturnNotPermitted` (0xE00002CD): the app has no Bluetooth authorisation.
    static let kIOReturnNotPermitted: IOReturn = IOReturn(bitPattern: 0xE000_02CD)
    /// `kIOReturnExclusiveAccess` (0xE00002C5): the channel is already open elsewhere.
    static let kIOReturnExclusiveAccess: IOReturn = IOReturn(bitPattern: 0xE000_02C5)

    private(set) var deviceName: String?
    private(set) var permissionDenied = false
    private var lastReachable = false
    private var lastReachableDate = Date.distantPast

    /// Whether the buds were connected as of the last command.
    var isReachable: Bool {
        lastReachable && Date().timeIntervalSince(lastReachableDate) <= Self.reachabilityLifetime
    }

    /// Whether a command is in flight.
    var isBusy: Bool { pending != nil }

    /// Receives frames that do not answer the command in flight (unsolicited reports).
    var onFrame: ((OPPFrame) -> Void)?

    private var channel: IOBluetoothRFCOMMChannel?
    private var reader = OPPFrameReader()
    private var sequence: UInt8 = 0xF0
    private var pending: PendingCommand?
    private var waitingOpen = false
    private var handshakeSent = false
    private var openTimer: DispatchSourceTimer?
    private var replyTimer: DispatchSourceTimer?
    private var idleTimer: DispatchSourceTimer?

    // MARK: - Commands

    /// Sends one request and waits for the reply that echoes its sequence number.
    func perform(
        expected: (command: UInt8, messageType: UInt8),
        timeout: TimeInterval,
        mismatchError: ControlError = .noReply,
        request: (UInt8) -> OPPFrame?,
        parse: @escaping (OPPFrame) -> NoiseState?,
        completion: @escaping @MainActor (Result<NoiseState, ControlError>) -> Void
    ) {
        guard pending == nil else { return }
        guard let frame = request(nextSequence()) else {
            completion(.failure(.unsupportedDevice))
            return
        }
        pending = PendingCommand(
            sequence: frame.sequence,
            expected: expected,
            payload: frame.encoded,
            mismatchError: mismatchError,
            parse: parse,
            completion: completion
        )
        flush()
        if pending != nil { armReplyTimer(seconds: timeout) }
    }

    private func nextSequence() -> UInt8 {
        // 0xF0 upwards; 0xFF is the last value before wrapping back to 0xF0.
        let value = sequence
        sequence = value == 0xFF ? 0xF0 : value &+ 1
        return value
    }

    /// Sends the pending command, opening the control channel first when needed.
    private func flush() {
        guard let command = pending, !waitingOpen else { return }
        guard let channel, channel.isOpen() else {
            self.channel = nil
            handshakeSent = false
            reader.reset()
            openChannel()
            return
        }
        if !handshakeSent {
            handshakeSent = true
            _ = write(OPPMessage.hello(sequence: command.sequence).encoded, on: channel)
        }
        guard write(command.payload, on: channel) else {
            finish(.failure(permissionDenied ? .permissionDenied : .openFailed))
            return
        }
        scheduleIdleClose()
    }

    private func write(_ bytes: [UInt8], on channel: IOBluetoothRFCOMMChannel) -> Bool {
        guard !bytes.isEmpty else { return false }
        var copy = bytes
        let count = UInt16(copy.count)
        let result = copy.withUnsafeMutableBytes { raw in
            channel.writeAsync(raw.baseAddress!, length: count, refcon: nil)
        }
        if result == Self.kIOReturnNotPermitted { permissionDenied = true }
        return result == kIOReturnSuccess
    }

    private func finish(_ result: Result<NoiseState, ControlError>) {
        replyTimer?.cancel()
        replyTimer = nil
        guard let command = pending else { return }
        pending = nil
        command.completion(result)
        if case .failure = result { closeChannel() }
    }

    private func armReplyTimer(seconds: TimeInterval) {
        replyTimer?.cancel()
        replyTimer = Self.timer(after: seconds) { [weak self] in
            self?.finish(.failure(.noReply))
        }
    }

    private func scheduleIdleClose() {
        idleTimer?.cancel()
        idleTimer = Self.timer(after: Self.idleTimeout) { [weak self] in
            guard let self, self.pending == nil else { return }
            self.closeChannel()
        }
    }

    // MARK: - Opening

    private func openChannel() {
        waitingOpen = true
        guard let record = Self.findServiceRecord(
            &deviceName, &lastReachable, &permissionDenied, &connectedDevice
        ), let device = connectedDevice else {
            waitingOpen = false
            finish(.failure(permissionDenied ? .permissionDenied : .notConnected))
            return
        }

        var channelID: BluetoothRFCOMMChannelID = 0
        guard record.getRFCOMMChannelID(&channelID) == kIOReturnSuccess else {
            waitingOpen = false
            finish(.failure(.openFailed))
            return
        }

        var channel: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelAsync(&channel, withChannelID: channelID, delegate: self)
        guard status == kIOReturnSuccess || status == Self.kIOReturnExclusiveAccess else {
            waitingOpen = false
            if status == Self.kIOReturnNotPermitted { permissionDenied = true }
            finish(.failure(permissionDenied ? .permissionDenied : .openFailed))
            return
        }
        guard let channel else {
            waitingOpen = false
            finish(.failure(.openFailed))
            return
        }
        self.channel = channel
        channel.setDelegate(self)
        openTimer = Self.timer(after: Self.openTimeout) { [weak self] in
            guard let self, self.waitingOpen else { return }
            self.openTimer = nil
            self.waitingOpen = false
            self.channel = nil
            self.finish(.failure(.openFailed))
        }
    }

    private func channelDidOpen() {
        openTimer?.cancel()
        openTimer = nil
        guard waitingOpen else { return }
        waitingOpen = false
        guard pending != nil else { closeChannel(); return }
        flush()
        if pending != nil { armReplyTimer(seconds: BluetoothControlChannel.replyTimeout) }
    }

    // MARK: - Closing

    func closeChannel() {
        openTimer?.cancel()
        openTimer = nil
        idleTimer?.cancel()
        idleTimer = nil
        waitingOpen = false
        handshakeSent = false
        reader.reset()
        if let channel {
            channel.close()
            self.channel = nil
        }
    }

    private func received(_ chunk: [UInt8]) {
        for frame in reader.append(chunk) {
            if let command = pending, frame.sequence == command.sequence,
               frame.command == command.expected.command,
               frame.messageType == command.expected.messageType {
                if let state = command.parse(frame) {
                    finish(.success(state))
                } else {
                    finish(.failure(command.mismatchError))
                }
                continue
            }
            onFrame?(frame)
        }
        if pending != nil { scheduleIdleClose() }
    }

    // MARK: - Discovery

    private var connectedDevice: IOBluetoothDevice?

    /// Finds the paired earbuds and their control service record.
    static func findServiceRecord(
        _ name: inout String?,
        _ reachable: inout Bool,
        _ denied: inout Bool,
        _ device: inout IOBluetoothDevice?
    ) -> IOBluetoothSDPServiceRecord? {
        guard let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            return nil
        }
        let serviceUUID = IOBluetoothSDPUUID(data: Data(serviceUUIDBytes))
        for candidate in devices where candidate.isConnected() {
            guard let record = candidate.getServiceRecord(for: serviceUUID) else { continue }
            name = candidate.name
            reachable = true
            device = candidate
            _ = denied
            return record
        }
        return nil
    }

    // MARK: - Timers

    static func timer(after seconds: TimeInterval, _ body: @escaping () -> Void) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler(handler: body)
        timer.resume()
        return timer
    }
}

// MARK: - IOBluetoothRFCOMMChannelDelegate

// IOBluetooth delivers these callbacks on the main run loop, so hopping to the main
// actor here is a precondition check, not a thread switch.
extension BluetoothTransport: @preconcurrency IOBluetoothRFCOMMChannelDelegate {
    func rfcommChannelOpenComplete(
        _ channel: IOBluetoothRFCOMMChannel!,
        status: IOReturn
    ) {
        if status == kIOReturnSuccess {
            channelDidOpen()
        } else {
            if status == Self.kIOReturnNotPermitted { permissionDenied = true }
            openTimer?.cancel()
            openTimer = nil
            waitingOpen = false
            self.channel = nil
            finish(.failure(permissionDenied ? .permissionDenied : .openFailed))
        }
    }

    func rfcommChannelData(
        _ channel: IOBluetoothRFCOMMChannel!,
        data dataPointer: UnsafeMutableRawPointer!,
        length dataLength: Int
    ) {
        guard dataLength > 0, let dataPointer else { return }
        let bytes = UnsafeBufferPointer(
            start: dataPointer.assumingMemoryBound(to: UInt8.self), count: dataLength)
        received(Array(bytes))
    }

    func rfcommChannelClosed(_ channel: IOBluetoothRFCOMMChannel!) {
        guard self.channel != nil else { return }
        self.channel = nil
        handshakeSent = false
        reader.reset()
        if pending != nil { finish(.failure(.closed)) } else { closeChannel() }
    }
}

// MARK: - Pending command

struct PendingCommand {
    var sequence: UInt8
    var expected: (command: UInt8, messageType: UInt8)
    var payload: [UInt8]
    var mismatchError: ControlError
    var parse: (OPPFrame) -> NoiseState?
    var completion: @MainActor (Result<NoiseState, ControlError>) -> Void
}
