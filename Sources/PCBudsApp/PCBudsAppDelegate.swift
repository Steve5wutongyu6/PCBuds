import AppKit
import PCBudsKit
import PCBudsUI

/// Owns everything that outlives a single interaction: the F5 tap, the Accessibility grant,
/// sleep/wake recovery and the menu-bar item.
///
/// The app is a background agent: no dock icon, no window at launch, and nothing touches
/// Bluetooth until the user asks for a switch.
@MainActor
final class PCBudsAppDelegate: NSObject, NSApplicationDelegate {
    private let controller = NoiseController.shared
    private var functionKeys = FunctionKeyTap()
    /// The one permission window, whatever it currently shows.
    private var permissionWindow: PermissionWindowController?
    /// Which permission that window is asking for; `nil` when no window is up.
    private var permissionShown: PermissionView.Kind?
    private var statusItem: StatusItemController?
    private lazy var authorization = AccessibilityAuthorization { [weak self] in
        self?.accessibilityGranted()
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.onPermissionNeeded = { [weak self] in
            MainActor.assumeIsolated { self?.showBluetoothPermission() }
        }
        controller.onModeChanged = { [weak self] _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        functionKeys.start()
        installTap()

        statusItem = StatusItemController(controller: controller) { [weak self] in
            self?.toggle()
        }

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

    // MARK: - F5

    private func installTap() {
        guard authorization.isGranted else {
            // Access is missing: do not even try to build the tap, and explain how to grant it.
            showAccessibilityPermission()
            return
        }
        functionKeys.onPress = { [weak self] in
            DispatchQueue.main.async { self?.toggle() }
        }
        let capability = functionKeys.startTap()
        if capability.isEmpty {
            // Trusted on paper but still refused — keep polling and keep the prompt in sight.
            showAccessibilityPermission()
        } else {
            dismissPermissionWindow()
        }
    }

    private func toggle() {
        controller.cycle()
        updateStatusItem()
    }

    // MARK: - Accessibility

    private func accessibilityGranted() {
        functionKeys.restartTap()
        dismissPermissionWindow(unless: .bluetooth)
    }

    private func showAccessibilityPermission() {
        // One window at a time: an open Bluetooth prompt is replaced, never stacked.
        let window = permissionWindow ?? PermissionWindowController()
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
        } else {
            // Reopens the prompt when the grant arrived while the app was not running.
            authorization.check()
        }
    }

    @objc private func openSystemSettings() {
        authorization.openSystemSettings()
    }

    // MARK: - Bluetooth

    private func showBluetoothPermission() {
        // Bluetooth access is only checked on a switch attempt, so bring the app forward to say
        // why nothing happened — replacing a stale prompt instead of stacking a second window.
        let window = permissionWindow ?? PermissionWindowController()
        permissionShown = .bluetooth
        window.present(kind: .bluetooth)
        window.onRetry = { [weak self] in self?.toggle() }
        window.onOpenSettings = {
            let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")
            if let settings { NSWorkspace.shared.open(settings) }
        }
        permissionWindow = window
    }

    // MARK: - Sleep

    @objc private func systemDidWake() {
        // The event system pauses over sleep; a tap built before it no longer captures.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            _ = self.functionKeys.restartTap()
            self.authorization.check()
        }
    }

    // MARK: - Menu bar

    private func updateStatusItem() {
        statusItem?.updateButton()
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