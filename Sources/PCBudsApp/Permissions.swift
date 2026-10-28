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

    /// Repairs a grant that exists but does not apply.
    ///
    /// System Settings keys an Accessibility grant to the app's code signature and location. A
    /// copy that was re-signed or moved keeps its row in the list, switched on, while the system
    /// keeps refusing it — which looks exactly like a missing grant from here, and no amount of
    /// re-checking clears it. Only the app's own stale record can be discarded, so that is what
    /// happens, followed by the system's own prompt so the row comes back with the right identity.
    /// - Returns: `true` when access is already available and nothing had to be repaired.
    @discardableResult
    func repair() -> Bool {
        if isGranted { return true }
        discardOwnRecord()
        askSystemForAccess()
        return isGranted
    }

    /// Drops this app's own Accessibility record, leaving every other app's grants untouched.
    private func discardOwnRecord() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", "Accessibility", identifier]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return }
        task.waitUntilExit()
    }

    /// Shows the system's own Accessiblity prompt, which also registers the app in the list.
    private func askSystemForAccess() {
        // The key is a global var in ApplicationServices, so it is read once here rather than
        // being passed around; the prompt itself is the system's, not this app's.
        let key = "AXTrustedCheckOptionPrompt"
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}