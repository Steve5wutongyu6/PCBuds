import ApplicationServices
import CoreGraphics

/// Swallows F5 system-wide and reports every physical key press.
///
/// Carbon hotkeys can observe F5 but never suppress it, so the app has to inspect the event
/// stream itself. The tap runs on a private thread with its own run loop: a busy main thread
/// then never trips the tap watchdog, and a tap that does get disabled by a timeout is
/// re-enabled silently instead of counting against the app's Accessibility grant.
///
/// Key codes are matched instead of key characters, so F5 stays F5 on every keyboard layout,
/// and the F5 key-up is consumed too so the key cannot linger half-pressed in other apps.
final class FunctionKeyTap: @unchecked Sendable {
    /// The event kinds a successful tap captures. A tap that captures nothing could not be
    /// created — which is what macOS reports for an app without the Accessibility grant.
    struct Capability: OptionSet, Sendable {
        let rawValue: Int

        static let keyDown = Capability(rawValue: 1 << 0)
        static let keyUp = Capability(rawValue: 1 << 1)
        static let both: Capability = [.keyDown, .keyUp]
    }

    /// Virtual key code of F5 (0x60).
    static let keyCode: Int64 = 96

    /// Called on the tap thread for every F5 press; the handler must bounce to the main thread.
    var onPress: (() -> Void)?

    private let lock = NSLock()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var keepAlive: CFRunLoopSource?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapIsActive = false
    private var generation = 0
    private var shouldExit = false

    /// Whether F5 is being captured right now.
    var isActive: Bool {
        lock.withLock { tapIsActive }
    }

    // MARK: - Lifecycle

    /// Starts the tap thread. Events are only captured once `startTap()` succeeds.
    func start() {
        lock.withLock {
            guard thread == nil else { return }
            shouldExit = false
            let thread = Thread { [self] in run() }
            thread.name = "PCBuds.key-tap"
            thread.qualityOfService = .userInteractive
            thread.stackSize = 128 << 10
            self.thread = thread
            thread.start()
        }
    }

    /// Stops capturing and lets the tap thread exit.
    func stop() {
        lock.withLock {
            shouldExit = true
            wakeLocked()
        }
    }

    // MARK: - Tap control

    /// Installs a fresh tap and returns what it captures. An empty result means the tap could
    /// not be created — the usual cause is a missing Accessibility grant.
    @discardableResult
    func startTap() -> Capability {
        let request: (generation: Int, active: Bool) = lock.withLock { (generation, tapIsActive) }
        guard !request.active else { return .both }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, _, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let tap = Unmanaged<FunctionKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
            return tap.handle(event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            return []
        }

        let installed = lock.withLock { () -> Bool in
            guard request.generation == generation, !tapIsActive, let runLoop else { return false }
            tap = port
            tapSource = source
            tapIsActive = true
            CFRunLoopAddSource(runLoop, source, .commonModes)
            return true
        }
        guard installed else { return [] }

        CGEvent.tapEnable(tap: port, enable: true)
        return CGEvent.tapIsEnabled(tap: port) ? .both : []
    }

    /// Discards the current tap. A tap left running after sleep or a settings change can keep
    /// an outdated event filter, so it is always replaced rather than re-enabled.
    func stopTap() {
        let runLoop: CFRunLoop? = lock.withLock {
            generation &+= 1
            let loop = self.runLoop
            removeTapLocked()
            return loop
        }
        // Releasing the port only takes effect on the tap thread's next pass.
        if let runLoop { CFRunLoopWakeUp(runLoop) }
    }

    @discardableResult
    func restartTap() -> Capability {
        stopTap()
        return startTap()
    }

    // MARK: - Tap thread

    private func run() {
        let keepAlive = Self.makeKeepAliveSource()
        lock.withLock {
            runLoop = CFRunLoopGetCurrent()
            self.keepAlive = keepAlive
        }
        if let keepAlive, let runLoop = CFRunLoopGetCurrent() as CFRunLoop? {
            CFRunLoopAddSource(runLoop, keepAlive, .commonModes)
        }

        while !lock.withLock({ shouldExit }) {
            _ = CFRunLoopRunInMode(.defaultMode, Date.distantFuture.timeIntervalSinceReferenceDate, true)
        }

        lock.withLock {
            removeTapLocked()
            if let keepAlive { CFRunLoopSourceInvalidate(keepAlive) }
            self.keepAlive = nil
            runLoop = nil
            thread = nil
        }
    }

    private func wakeLocked() {
        guard let runLoop else { return }
        CFRunLoopStop(runLoop)
    }

    private func removeTapLocked() {
        guard tapIsActive else { return }
        tapIsActive = false
        if let tapSource, let runLoop { CFRunLoopRemoveSource(runLoop, tapSource, .commonModes) }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        tapSource = nil
    }

    private static func makeKeepAliveSource() -> CFRunLoopSource? {
        var context = CFRunLoopSourceContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil,
            equal: nil,
            hash: nil,
            schedule: nil,
            cancel: nil,
            perform: nil
        )
        return CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
    }

    // MARK: - Event handling

    private func handle(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch event.type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system switched the tap off. Turn it back on in place — rebuilding the tap
            // here would need another run-loop pass, and losing F5 for a moment is worse.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)

        case .keyDown, .keyUp:
            guard event.getIntegerValueField(.keyboardEventKeycode) == Self.keyCode else {
                return Unmanaged.passUnretained(event)
            }
            if event.type == .keyDown,
               event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                onPress?()
            }
            // Swallow the press, its auto-repeats and the matching release.
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}