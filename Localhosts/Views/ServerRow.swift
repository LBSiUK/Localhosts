import SwiftUI

struct ServerRow: View {
    enum Kind {
        case live
        case ended
        case other
    }

    let server: Server
    let store: Store
    let kind: Kind

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(verbatim: ":\(server.port)")
                .font(.system(size: 14.5, weight: .semibold, design: .monospaced))
                .frame(minWidth: 56, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(server.label)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .help(details)

            Spacer(minLength: 4)

            HStack(spacing: 0) {
                IconButton(symbol: "safari", help: "Open \(server.url.absoluteString)") {
                    store.open(server)
                }
                switch kind {
                case .live:
                    IconButton(symbol: "apple.terminal", help: "Go to the Claude terminal") {
                        store.goToTerminal(server)
                    }
                case .ended:
                    IconButton(symbol: "arrow.counterclockwise", help: "Resume this Claude session in a new Terminal window") {
                        store.resume(server)
                    }
                case .other:
                    EmptyView()
                }
                stopButton
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .opacity(store.stopping.contains(server.id) ? 0.5 : 1)
    }

    @ViewBuilder private var stopButton: some View {
        if store.stopping.contains(server.id) {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
        } else if let refusal = server.stopRefusal {
            IconButton(symbol: "stop.circle", help: refusal, enabled: false) {}
        } else {
            IconButton(symbol: "stop.circle", help: server.launchdLabel == nil ? "Stop" : "Stop (launchd will start it again)", tint: .red) {
                store.stop(server)
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if kind == .ended, let title = store.endedTitle(for: server) { parts.append(title) }
        if let folder = server.folderName { parts.append(folder) }
        parts.append(Uptime.text(since: server.startTime))
        if server.launchdLabel != nil { parts.append("restarts automatically") }
        return parts.joined(separator: " · ")
    }

    private var details: String {
        var lines = [server.command, "PID \(server.pid) · \(server.address):\(server.port)"]
        if let cwd = server.cwd { lines.append(cwd) }
        if let label = server.launchdLabel { lines.append("launchd: \(label)") }
        return lines.joined(separator: "\n")
    }
}
