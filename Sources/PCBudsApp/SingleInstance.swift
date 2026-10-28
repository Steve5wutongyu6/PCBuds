import AppKit

/// PCBuds is a login-item style agent: a second copy must not open a second F5 tap. A copy that
/// finds the app already running hands over to it and leaves.
enum SingleInstance {
    /// Whether another copy of this app is already running.
    static func isAlreadyRunning() -> Bool {
        guard let identifier = Bundle.main.bundleIdentifier else { return false }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
        let me = ProcessInfo.processInfo.processIdentifier
        return running.contains { $0.processIdentifier != me }
    }

    /// Brings the running copy forward (its permission window, if any) and quits this one.
    static func yieldToRunningCopy() -> Never {
        if let identifier = Bundle.main.bundleIdentifier,
           let other = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
               .first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate()
        }
        exit(EXIT_SUCCESS)
    }
}
