import SwiftUI

/// The one piece of foreground UI in PCBuds: shown only when a permission is missing, and
/// closed the moment the permission arrives.
///
/// Restrained by design — a heading naming the switch that has to be turned on, the exact
/// path in System Settings, then the two actions. No hero icon, no subtitle restating the
/// heading, no footer.
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
        VStack(spacing: 20) {
            PermissionHeading(kind: kind)
            PermissionPath(kind: kind, appName: appName)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            PermissionActions(onOpenSettings: onOpenSettings, onRetry: onRetry)
        }
        .frame(maxWidth: 360)
        .padding(.horizontal, 24)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 20)
        .frame(minWidth: 460, idealWidth: 460, maxWidth: .infinity)
        .frame(height: 250, alignment: .top)
        .accessibilityElement(children: .contain)
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

private struct PermissionPath: View {
    let kind: PermissionView.Kind
    let appName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("系统设置 · 隐私与安全性")
                .font(.caption)
                .foregroundStyle(.secondary)
            Label {
                Text(path)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "gearshape")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(nsColor: .quaternarySystemFill), in: .rect(cornerRadius: 8))
        }
        .accessibilityElement(children: .combine)
    }

    private var path: String {
        switch kind {
        case .accessibility:
            "辅助功能 → 勾选「\(appName)」"
        case .bluetooth:
            "蓝牙 → 允许「\(appName)」"
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