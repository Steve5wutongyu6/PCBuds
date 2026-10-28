import SwiftUI

/// The one piece of foreground UI in PCBuds: shown only when a permission is missing, and
/// closed the moment the permission arrives.
///
/// Restrained by design — the permission's symbol, a heading naming the switch that has to be
/// turned on, one rounded list with the path to it, then the two actions. No subtitle restating
/// the heading, no footer.
public struct PermissionView: View {
    /// Which system switch the window is asking about.
    public enum Kind: Sendable {
        case accessibility
        case bluetooth
    }

    private let kind: Kind
    private let appName: String
    private let onOpenSettings: () -> Void
    private let onRetry: () -> Void

    public init(
        kind: Kind,
        appName: String = "PCBuds",
        onOpenSettings: @escaping () -> Void,
        onRetry: @escaping () -> Void
    ) {
        self.kind = kind
        self.appName = appName
        self.onOpenSettings = onOpenSettings
        self.onRetry = onRetry
    }

    public var body: some View {
        VStack(spacing: 14) {
            PermissionIcon(kind: kind)
            PermissionHeading(kind: kind)
            PermissionRoute(kind: kind, appName: appName)
            Spacer(minLength: 0)
            PermissionActions(onOpenSettings: onOpenSettings, onRetry: onRetry)
        }
        .frame(maxWidth: 380)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .frame(width: 460, height: 250, alignment: .top)
        .accessibilityElement(children: .contain)
    }
}

extension PermissionView.Kind {
    /// The SF Symbol that stands for the permission the window asks for.
    var symbolName: String {
        switch self {
        case .accessibility: "accessibility"
        case .bluetooth: "antenna.radiowaves.left.and.right"
        }
    }
}

// MARK: - Icon

private struct PermissionIcon: View {
    let kind: PermissionView.Kind

    var body: some View {
        Image(systemName: kind.symbolName)
            .font(.system(size: 28, weight: .regular))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityHidden(true)
    }
}

// MARK: - Heading

private struct PermissionHeading: View {
    let kind: PermissionView.Kind

    var body: some View {
        Text(kind == .accessibility ? "需要开启辅助功能" : "需要开启蓝牙")
            .font(.title2.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Path in System Settings

/// The whole route as one list: where to go, then what to turn on.
private struct PermissionRoute: View {
    let kind: PermissionView.Kind
    let appName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(symbol: "gearshape", text: "系统设置 · 隐私与安全性")
            Divider()
                .padding(.leading, 28)
            row(symbol: kind.symbolName, text: step)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .quaternarySystemFill), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private func row(symbol: String, text: String) -> some View {
        Label {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
        }
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 9)
    }

    private var step: String {
        switch kind {
        case .accessibility: "辅助功能 → 勾选「\(appName)」"
        case .bluetooth: "蓝牙 → 允许「\(appName)」"
        }
    }
}

// MARK: - Actions

private struct PermissionActions: View {
    let onOpenSettings: () -> Void
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 0)
            Button("打开系统设置", action: onOpenSettings)
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            Button("重新检测", action: onRetry)
                .controlSize(.large)
        }
    }
}

#Preview("辅助功能", traits: .sizeThatFitsLayout) {
    PermissionView(kind: .accessibility, onOpenSettings: {}, onRetry: {})
}

#Preview("蓝牙", traits: .sizeThatFitsLayout) {
    PermissionView(kind: .bluetooth, onOpenSettings: {}, onRetry: {})
}
