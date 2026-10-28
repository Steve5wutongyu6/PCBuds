import AppKit
import SwiftUI

/// Hosts `PermissionView` in a regular window and releases the window once it closes, so a
/// running, idle app keeps no view hierarchy in memory.
@MainActor
public final class PermissionWindowController {
    public var onOpenSettings: (() -> Void)?
    public var onRetry: (() -> Void)?

    private var window: NSWindow?

    public init() {}

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
        self.window = window
        show(window)
    }

    /// Brings the app forward and disposes of the window.
    public func close() {
        guard let window else { return }
        NSApp.deactivate()
        window.orderOut(nil)
        window.contentView = nil
        window.close()
        self.window = nil
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