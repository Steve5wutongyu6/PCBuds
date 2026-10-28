import ApplicationServices
import CoreGraphics

/// Swallows F5 system-wide and reports every physical key press.
///
/// Carbon hotkeys can observe F5 but never suppress it, so the app has to inspect the event
/// stream itself. The tap runs on a private thread with its own run loop: a busy main thread
/// then never trips the tap watchdog, and a tap the system switches off is rebuilt on that same
/// thread instead of counting against the app's Accessibility grant.
///
/// The tap is created **on its own thread**, never by the caller: CGEvent.tapCreate has to be
/// installed on the run loop that will service it, and that run loop only exists once the thread
/// is running. Building it from the caller raced the thread's start-up, and a lost race looked
/// exactly like a missing Accessibility grant — the app raised its permission window on a machine
/// where access had already been granted. Callers therefore only *ask* for a tap; "isCapturing"
/// reports what the thread actually built.
///
/// Key codes are matched instead of key characters, so F5 stays F5 on every keyboard layout, and
/// the F5 key-up is consumed too so the key cannot linger half-pressed in other apps.
final class FunctionKeyTap: @unchecked Sendable {
    /// Virtual key code of F5 (0x60).
    static let keyCode: Int64 = 96

    /// How long each run-loop pass waits before the tap is re-checked.
    private static let selfHealInterval: CFTimeInterval = 2

    /// Called on the tap thread for every F5 press; the handler must bounce to the main thread.
    var onPress: (() -> Void)?

    private let lock = NSLock()
    private var thread: Thread?
    private var runLoop: CFRunLoop?
    private var keepAlive: CFRunLoopSource?
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var tapIsActive = false
    /// Set by callers, acted on by the tap thread.
    private var wantsTap = false
    private var shouldExit = false

    /// Whether F5 is being captured right now. Safe to read from any thread.
    var isCapturing: Bool {
        lock.withLock { tapIsActive }
    }

    // MARK: - Lifecycle

    /// Starts the tap thread. Capture begins once the thread has built its tap.
    func start() {
        lock.withLock {
            guard thread == nil else { return }
            shouldExit = false
            wantsTap = true
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
            wantsTap = false
            if let runLoop { CFRunLoopStop(runLoop) }
        }
    }

    // MARK: - Tap control

    /// Asks for a fresh tap. Returns immediately; the thread builds it on its own run loop and
    /// "isCapturing" reports the result. An existing tap is replaced, because a tap left running
    /// across sleep or a settings change can keep an outdated event filter.
    func rebuild() {
        lock.withLock {
            wantsTap = true
            tearDownTapLocked()
            if let runLoop { CFRunLoopWakeUp(runLoop) }
        }
    }

    // MARK: - Tap thread

    private func run() {
        let keepAlive = Self.makeKeepAliveSource()
        let loop = CFRunLoopGetCurrent()
        lock.withLock {
            runLoop = loop
            self.keepAlive = keepAlive
        }
        if let keepAlive {
            CFRunLoopAddSource(loop, keepAlive, .commonModes)
        }

        while !lock.withLock({ shouldExit }) {
            installTapIfWanted()
            // A bounded pass keeps the self-heal independent of incoming events: the system can
            // switch a tap off without the process being told.
            _ = CFRunLoopRunInMode(.defaultMode, Self.selfHealInterval, true)
            verifyTap()
        }

        lock.withLock {
            tearDownTapLocked()
            if let keepAlive { CFRunLoopSourceInvalidate(keepAlive) }
            self.keepAlive = nil
            runLoop = nil
            thread = nil
        }
    }

    /// Builds the tap when one is wanted and none is running. Runs on the tap thread.
    private func installTapIfWanted() {
        let wanted = lock.withLock { wantsTap && !tapIsActive && !shouldExit }
        guard wanted else { return }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
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
        ) else {
            // No grant, or the event system refuses right now. The next pass tries again.
            return
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return
        }

        let installed = lock.withLock { () -> Bool in
            guard wantsTap, !tapIsActive, !shouldExit, let runLoop else { return false }
            tap = port
            tapSource = source
            tapIsActive = true
            CFRunLoopAddSource(runLoop, source, .commonModes)
            return true
        }
        guard installed else {
            CFMachPortInvalidate(port)
            return
        }
        CGEvent.tapEnable(tap: port, enable: true)
        if !CGEvent.tapIsEnabled(tap: port) {
            lock.withLock { tearDownTapLocked() }
        }
    }

    /// Replaces a tap the system switched off. Runs on the tap thread.
    private func verifyTap() {
        let state: (wanted: Bool, usable: Bool) = lock.withLock {
            guard wantsTap else { return (false, false) }
            let usable = tapIsActive && (tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false)
            return (true, usable)
        }
        guard state.wanted else { return }
        guard state.usable else {
            lock.withLock { tearDownTapLocked() }
            installTapIfWanted()
            return
        }
    }

    /// Removes the tap. The port is released on the thread that installed its run-loop source.
    private func tearDownTapLocked() {
        guard tapIsActive || tap != nil else { return }
        tapIsActive = false
        if let tapSource, let runLoop {
            CFRunLoopRemoveSource(runLoop, tapSource, .commonModes)
        }
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
            // Dropping the tap here and letting the thread rebuild is the only safe move:
            // rebuilding from inside the callback deadlocks.
            lock.withLock { tearDownTapLocked() }
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
