import AppKit
import PCBudsKit
import PCBudsUI

/// Owns everything that outlives a single interaction: the F5 tap, the Accessibility grant,
/// sleep/wake recovery and the one permission window.
///
/// The app is a background agent with no menu bar: no dock icon, no status item, no window at
/// launch, and nothing touches Bluetooth until the user asks for a switch. The permission
/// window is the only UI it ever shows; quitting is the standard ⌘Q while that window is key
/// (see `ApplicationMenu`).
@MainActor
final class PCBudsAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = NoiseController.shared
    private var functionKeys = FunctionKeyTap()
    private let applicationMenu = ApplicationMenu()
    /// The one permission window, whatever it currently shows.
    private var permissionWindow: PermissionWindowController?
    /// Which permission that window is asking for; `nil` when no window is up.
    private var permissionShown: PermissionView.Kind?
    private lazy var authorization = AccessibilityAuthorization { [weak self] in
        self?.accessibilityGranted()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // No menu bar item for a background agent — but a menu still has to exist, or AppKit
        // never forwards the ⌘Q typed in the permission window.
        applicationMenu.install()

        controller.onPermissionNeeded = { [weak self] in
            MainActor.assumeIsolated { self?.showBluetoothPermission() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        installTap()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(recheckPermissions),
            name: .pcBudsRecheck,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSystemSettings),
            name: .pcBudsOpenSettings,
            object: nil
        )

    }

    func applicationWillTerminate(_ notification: Notification) {
        authorization.stopPolling()
        functionKeys.stop()
        permissionWindow?.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, !authorization.isGranted { showAccessibilityPermission() }
        return false
    }

    /// Whether ⌘Q may quit: only while the permission window is up, so a running background
    /// agent can never be closed by a stray shortcut.
    var canQuitFromWindow: Bool {
        permissionWindow != nil
    }

    // MARK: - F5

    private func installTap() {
        functionKeys.onPress = { [weak self] in
            DispatchQueue.main.async { self?.toggle() }
        }
        // The thread starts on its own and builds the tap there; asking before it is running is
        // what used to make a granted machine look unauthorised.
        functionKeys.start()
        functionKeys.rebuild()
        // The window follows the grant alone. A tap that is still being installed is not
        // evidence of anything, and the thread keeps retrying on its own.
        if authorization.isGranted {
            dismissPermissionWindow()
        } else {
            showAccessibilityPermission()
        }
    }

    private func toggle() {
        controller.cycle()
    }

    // MARK: - Accessibility

    private func accessibilityGranted() {
        functionKeys.rebuild()
        dismissPermissionWindow(unless: .bluetooth)
    }

    private func showAccessibilityPermission() {
        // One window at a time: an open Bluetooth prompt is replaced, never stacked.
        let window = permissionWindow ?? makePermissionWindow()
        permissionShown = .accessibility
        window.present(kind: .accessibility)
        window.onRetry = { [weak self] in self?.recheckPermissions() }
        window.onOpenSettings = { [weak self] in self?.openSystemSettings() }
        permissionWindow = window
        authorization.startPolling()
    }

    @objc private func recheckPermissions() {
        if authorization.isGranted {
            accessibilityGranted()
            return
        }
        // Re-checking something the system has already decided cannot help. The user says the
        // switch is on, so the grant is there but no longer applies — repair it, then keep
        // polling: the window closes by itself as soon as the new row takes effect.
        authorization.repair()
        authorization.check()
    }

    @objc private func openSystemSettings() {
        authorization.openSystemSettings()
    }

    // MARK: - Bluetooth

    private func showBluetoothPermission() {
        // Bluetooth access is only checked on a switch attempt, so bring the app forward to say
        // why nothing happened — replacing a stale prompt instead of stacking a second window.
        let window = permissionWindow ?? makePermissionWindow()
        permissionShown = .bluetooth
        window.present(kind: .bluetooth)
        window.onRetry = { [weak self] in self?.toggle() }
        window.onOpenSettings = {
            let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
            if let settings { NSWorkspace.shared.open(settings) }
        }
        permissionWindow = window
    }

    private func makePermissionWindow() -> PermissionWindowController {
        let window = PermissionWindowController()
        window.onClose = { [weak self] in self?.permissionWindowClosed() }
        return window
    }

    // MARK: - Sleep

    @objc private func systemDidWake() {
        // The event system pauses over sleep; a tap built before it no longer captures.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.functionKeys.rebuild()
            self.authorization.check()
        }
    }

    // MARK: - Window lifetime

    private func permissionWindowClosed() {
        permissionWindow = nil
        permissionShown = nil
    }

    private func dismissPermissionWindow() {
        permissionWindow?.close()
        permissionWindow = nil
        permissionShown = nil
    }

    /// Closes the prompt unless it is the Bluetooth one still waiting for an answer.
    private func dismissPermissionWindow(unless kind: PermissionView.Kind) {
        if permissionShown != kind { dismissPermissionWindow() }
    }
}

/// The app's main menu, built in code because the app ships without a nib.
///
/// With `LSUIElement` the menu bar is never drawn, but AppKit still installs this menu on
/// `NSApp`: a ⌘Q typed while the permission window is key travels the responder chain to the
/// application's terminate: action. The item is disabled unless that window exists — see
/// `PCBudsAppDelegate.canQuitFromWindow`.
@MainActor
final class ApplicationMenu {
    private let appMenu = AppMenuTarget()

    func install() {
        let mainMenu = NSMenu()
        let appItem = mainMenu.addItem(withTitle: "PCBuds", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "PCBuds")
        // `terminate(_:)` is spelled through `NSApplication.self` so the selector is unambiguous.
        let quit = submenu.addItem(
            withTitle: "退出 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "PCBuds")",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quit.keyEquivalentModifierMask = .command
        appItem.submenu = submenu
        appMenu.submenu = submenu
        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = nil
    }
}

/// A menu is only visible to the user at all when it is a pure command holder: validation then
/// decides whether ⌘Q does anything while no permission window is open.
private final class AppMenuTarget: NSObject, NSMenuItemValidation {
    var submenu: NSMenu?

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(NSApplication.terminate(_:)) else { return true }
        guard let delegate = NSApp.delegate as? PCBudsAppDelegate else { return true }
        return delegate.canQuitFromWindow
    }
}
