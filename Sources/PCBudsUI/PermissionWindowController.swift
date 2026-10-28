import AppKit
import SwiftUI

/// Hosts `PermissionView` in a regular window and releases the window once it closes, so a
/// running, idle app keeps no view hierarchy in memory.
@MainActor
public final class PermissionWindowController: NSObject, NSWindowDelegate {
    public var onOpenSettings: (() -> Void)?
    public var onRetry: (() -> Void)?
    /// Runs when the user closes the window themselves.
    public var onClose: (() -> Void)?

    private var window: NSWindow?

    public override init() {
        super.init()
    }

    /// Shows the window for `kind`, or re-fronts it when it is already showing.
    public func present(kind: PermissionView.Kind) {
        if let window {
            window.contentView = NSHostingView(rootView: content(for: kind))
            show(window)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 250),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "PCBuds"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = false
        window.contentView = NSHostingView(rootView: content(for: kind))
        // Closing the window counts as answering later, not as dismissing the question silently.
        window.delegate = self
        self.window = window
        show(window)
    }

    /// Brings the app forward and disposes of the window.
    public func close() {
        guard let window else { return }
        NSApp.deactivate()
        window.delegate = nil
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        self.window = nil
    }

    public func windowWillClose(_ notification: Notification) {
        guard let closed = notification.object as? NSWindow, closed === window else { return }
        closed.delegate = nil
        window = nil
        onClose?()
    }

    private func content(for kind: PermissionView.Kind) -> PermissionView {
        PermissionView(
            kind: kind,
            appName: Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "PCBuds",
            onOpenSettings: { [weak self] in self?.onOpenSettings?() },
            onRetry: { [weak self] in self?.onRetry?() }
        )
    }

    private func show(_ window: NSWindow) {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension Notification.Name {
    /// Asks for one more check of the permissions the app needs.
    public static let pcBudsRecheck = Notification.Name("PCBuds.recheckPermissions")
    /// Opens the relevant System Settings pane.
    public static let pcBudsOpenSettings = Notification.Name("PCBuds.openSystemSettings")
}
