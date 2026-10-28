import AppKit
import PCBudsKit

/// The app's only standing UI: a monochrome template image in the menu bar.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let controller: NoiseController
    private let onToggle: () -> Void

    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    /// - Parameters:
    ///   - controller: Supplies the last mode the buds confirmed.
    ///   - onToggle: Cycles the noise mode, same as F5.
    init(controller: NoiseController, onToggle: @escaping () -> Void) {
        self.controller = controller
        self.onToggle = onToggle
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        // The item must exist before the first button update; without a button it is invisible.
        _ = statusItem.button

        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(.sectionHeader(title: "PCBuds"))
        menu.addItem(Self.item("切换模式", action: #selector(toggle), target: self, key: " "))
        menu.addItem(Self.item("重新检测权限", action: #selector(recheck), target: self, key: ""))
        menu.addItem(Self.item("打开系统设置", action: #selector(openSettings), target: self, key: ","))
        menu.addItem(.separator())
        menu.addItem(Self.item("退出", action: #selector(quit), target: self, key: "q"))
        statusItem.menu = menu
        updateButton()
    }

    /// Reflects the mode the buds last confirmed.
    func updateButton() {
        let mode = controller.lastKnownMode()
        statusItem.button?.image = NSImage(
            systemSymbolName: Self.symbol(for: mode),
            accessibilityDescription: mode.map { "PCBuds · \($0.label)" } ?? "PCBuds"
        )
    }

    func menuWillOpen(_ menu: NSMenu) {
        // Until a mode is confirmed there is nothing to switch from, so the item stays hidden.
        menu.item(withTag: Self.toggleTag)?.isHidden = controller.lastKnownMode() == nil
        updateButton()
    }

    // MARK: - Actions

    @objc private func toggle() { onToggle() }
    @objc private func recheck() { NotificationCenter.default.post(name: .pcBudsRecheck, object: nil) }
    @objc private func openSettings() { NotificationCenter.default.post(name: .pcBudsOpenSettings, object: nil) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Building blocks

    private static let toggleTag = 100

    private static func item(
        _ title: String,
        action: Selector,
        target: AnyObject,
        key: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        item.tag = action == #selector(StatusItemController.toggle) ? toggleTag : 0
        return item
    }

    /// One in-ear glyph for all three modes, so the item never changes shape in the menu bar;
    /// the mode itself is carried by the drawing variant.
    private static func symbol(for mode: NoiseMode?) -> String {
        switch mode {
        case .transparency: "earbuds.in.ear"
        default: "earbuds"
        }
    }
}

extension Notification.Name {
    static let pcBudsRecheck = Notification.Name("PCBuds.recheckPermissions")
    static let pcBudsOpenSettings = Notification.Name("PCBuds.openSystemSettings")
}