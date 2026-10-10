import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage("resumeCommand") private var resumeCommand = Store.defaultResumeCommand
    @AppStorage("showOther") private var showOther = true
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                    .onChange(of: openAtLogin) { _, on in
                        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
                    }
                Toggle("Show servers Claude didn't start", isOn: $showOther)
            }
            Section {
                TextField("Command", text: $resumeCommand)
                    .font(.system(.body, design: .monospaced))
                HStack {
                    Text("Runs in a new Terminal window, in the folder the session started in. {id} becomes the session id.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if resumeCommand != Store.defaultResumeCommand {
                        Button("Reset") { resumeCommand = Store.defaultResumeCommand }
                            .controlSize(.small)
                    }
                }
            } header: {
                Text("Resuming an ended session")
            }
            Section {
                Text("Localhosts puts the `localhosts` command in `~/.local/bin` and its Claude Code skill in `~/.claude/skills` each time it opens. Agents label their servers with `localhosts add <port> --label …`. Run `localhosts help` in Terminal for the rest.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Command line")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct MenuBarLabel: View {
    let store: Store

    var body: some View {
        let count = store.claudeCount
        if count > 0 {
            Text("\(Image(systemName: "server.rack")) \(count)")
        } else {
            Image(systemName: "server.rack")
        }
    }
}
