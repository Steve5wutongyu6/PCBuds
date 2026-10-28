import ApplicationServices
import AppKit

/// The Accessibility grant the F5 tap needs, read without ever showing a system prompt.
///
/// The prompt is a window from this app instead: it explains where the switch lives and polls
/// in the background, so granting access completes the setup without a relaunch.
@MainActor
final class AccessibilityAuthorization {
    /// How often the grant is re-checked while it is missing.
    static let pollInterval: TimeInterval = 3

    private let onGranted: () -> Void
    private var poll: Timer?
    private var wasGranted = false

    /// - Parameter onGranted: Runs on the main actor when access becomes available.
    init(onGranted: @escaping () -> Void) {
        self.onGranted = onGranted
    }

    /// Whether the system already trusts this app to inspect the event stream.
    var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Opens System Settings directly on the Accessibility pane.
    func openSystemSettings() {
        let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let settings { NSWorkspace.shared.open(settings) }
    }

    func startPolling() {
        check()
    }

    func stopPolling() {
        poll?.invalidate()
        poll = nil
    }

    /// Re-reads the grant right away, e.g. after the user comes back from System Settings.
    /// `onGranted` fires only for the missing -> granted transition, never on every check.
    func check() {
        if isGranted {
            stopPolling()
            if !wasGranted {
                wasGranted = true
                onGranted()
            }
            return
        }
        guard poll == nil else { return }
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        poll = timer
    }
}