import SwiftUI

/// The list shown in the menu bar dropdown and in the pinned window.
struct ServerList: View {
    let store: Store
    let pin: PinController

    @AppStorage("showOther") private var showOther = true
    @AppStorage("otherExpanded") private var otherExpanded = false
    @Environment(\.openSettings) private var openSettings
    @State private var listHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            banners
            Divider().opacity(0.6)
            content
        }
        .frame(width: 380)
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: Demo.openSettings)) { _ in openSettings() }
        #endif
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Localhosts")
                .font(.system(size: 13, weight: .semibold))
            if !store.servers.isEmpty {
                Text(summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            IconButton(symbol: pin.isPinned ? "pin.fill" : "pin",
                       help: pin.isPinned ? "Unpin from the desktop" : "Pin to the desktop") {
                pin.toggle()
            }
            Menu {
                Button("Refresh Now") { store.refresh() }
                Button("Settings…") {
                    NSApp.activate()
                    openSettings()
                }
                Divider()
                Button("Quit Localhosts") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 26, height: 26)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .fixedSize()
            .help("More")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var summary: String {
        let claude = store.claudeCount
        let other = store.otherServers.count
        if claude == 0 { return "\(other) other" }
        return claude == 1 ? "1 from Claude" : "\(claude) from Claude"
    }

    @ViewBuilder private var banners: some View {
        if store.needsAutomationPermission {
            Banner(symbol: "lock", text: "Allow Localhosts to control Terminal to jump to tabs.",
                   action: ("Open Settings", store.openAutomationSettings), dismiss: nil)
        }
        if let message = store.message {
            Banner(symbol: "exclamationmark.triangle", text: message, action: nil, dismiss: store.dismissMessage)
        }
    }

    // MARK: content

    @ViewBuilder private var content: some View {
        let others = showOther ? store.otherServers : []
        if store.claudeCount == 0 && others.isEmpty {
            EmptyState()
        } else {
            // As tall as the list, scrolling once it passes 470 points.
            ScrollView {
                sections(others: others)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(max(listHeight, 1), 470))
        }
    }

    private func sections(others: [Server]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.liveGroups) { group in
                SectionHeader(title: group.title, detail: group.session.tty)
                ForEach(group.servers) { server in
                    ServerRow(server: server, store: store, kind: .live)
                }
            }
            if !store.endedServers.isEmpty {
                SectionHeader(title: "Session ended", detail: nil)
                ForEach(store.endedServers) { server in
                    ServerRow(server: server, store: store, kind: .ended)
                }
            }
            if !others.isEmpty {
                OtherHeader(count: others.count, expanded: $otherExpanded)
                if otherExpanded {
                    ForEach(others) { server in
                        ServerRow(server: server, store: store, kind: .other)
                    }
                }
            }
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
    }
}

// MARK: - Pieces

struct SectionHeader: View {
    let title: String
    let detail: String?

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if let detail {
                Text(detail)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }
}

struct OtherHeader: View {
    let count: Int
    @Binding var expanded: Bool
    @State private var hovering = false

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Text("Other")
                    .font(.system(size: 11, weight: .semibold))
                Text("\(count)")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .foregroundStyle(hovering ? .primary : .secondary)
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Servers Claude didn't start")
    }
}

struct Banner: View {
    let symbol: String
    let text: String
    let action: (String, () -> Void)?
    let dismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            if let action {
                Button(action.0, action: action.1)
                    .controlSize(.small)
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Dismiss")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

struct EmptyState: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
            Text("No servers running")
                .font(.system(size: 12.5, weight: .medium))
            Text("Anything your agents start on localhost shows up here.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    var tint: Color? = nil
    var enabled = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .regular))
                .frame(width: 26, height: 26)
                .foregroundStyle(enabled ? AnyShapeStyle(hovering ? (tint ?? Color.primary) : Color.secondary) : AnyShapeStyle(.quaternary))
                .background(hovering && enabled ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}
