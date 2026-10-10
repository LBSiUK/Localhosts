import Foundation

/// Turns listening sockets into rows: finds the Claude session that started each server,
/// applies what agents registered, and drops system listeners.
struct Resolver {
    let source: ProcessSource
    let registry: [RegistryEntry]
    var ownPID: pid_t = getpid()

    func servers(from listeners: [Listener]) -> [Server] {
        listeners.compactMap(server(for:)).sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    func server(for listener: Listener) -> Server? {
        guard listener.pid != ownPID,
              let info = source.processes[listener.pid],
              !ProcessKind.isClaude(source.details(listener.pid), name: info.name),
              !ProcessKind.alwaysHidden.contains(info.name) else { return nil }

        let details = source.details(listener.pid)
        let entry = registry.first { $0.matches(listener, info: info) }
        let arguments = details?.args?.arguments ?? []
        let dockerForward = ProcessKind.isColimaForward(name: info.name, arguments: arguments)

        var owner = claimedOwner(of: info)
        if owner == .other, let entry {
            owner = Self.owner(claudePID: entry.claudePID, sessionID: entry.sessionID,
                               serverStart: info.startTime, source: source)
        }
        if owner == .other, entry == nil, !dockerForward,
           ProcessKind.isSystemListener(path: details?.path, name: info.name) {
            return nil
        }

        let command = arguments.isEmpty ? info.name : arguments.joined(separator: " ")
        var label = entry?.label ?? describe(info)
        if dockerForward, entry?.label == nil { label = "Docker container (Colima)" }

        let xpc = details?.environment["XPC_SERVICE_NAME"]
        let launchd = (info.ppid == 1 && xpc != nil && xpc != "0" && !xpc!.hasPrefix("application.")) ? xpc : nil

        return Server(pid: info.pid,
                      port: listener.port,
                      address: listener.address,
                      processName: info.name,
                      command: command,
                      // A Docker forward's own folder is wherever Colima was started; the agent's is the project.
                      cwd: dockerForward ? (entry?.cwd ?? details?.cwd) : (details?.cwd ?? entry?.cwd),
                      startTime: info.startTime,
                      label: label,
                      path: entry?.normalisedPath ?? "/",
                      owner: owner,
                      stopCommand: entry?.stopCommand,
                      launchdLabel: launchd,
                      isDockerForward: dockerForward)
    }

    /// Looks for the CLAUDE_PID that Claude Code puts in the environment of every command it runs:
    /// first on the listener, then its parents, then the rest of its process group. Renamed Node
    /// processes (next-server, npm exec) lose their own environment but their parents keep it.
    func claimedOwner(of info: ProcInfo) -> Owner {
        for pid in ProcessTree(source: source).ownershipCandidates(for: info) {
            let environment = source.details(pid)?.environment ?? [:]
            if let raw = environment["CLAUDE_PID"], let claudePID = pid_t(raw) {
                return Self.owner(claudePID: claudePID, sessionID: environment["CLAUDE_CODE_SESSION_ID"],
                                  serverStart: info.startTime, source: source)
            }
        }
        for ancestor in ProcessTree(source: source).ancestors(of: info.pid) {
            if ProcessKind.isClaude(source.details(ancestor.pid), name: ancestor.name) {
                return .live(ClaudeSession(claudePID: ancestor.pid, sessionID: nil, tty: ancestor.tty))
            }
        }
        return .other
    }

    /// A Claude PID only counts as live if that process is still Claude and is older than the
    /// server, so a recycled PID never points the button at the wrong tab.
    static func owner(claudePID: pid_t?, sessionID: String?, serverStart: TimeInterval, source: ProcessSource) -> Owner {
        if let claudePID, let claude = source.processes[claudePID],
           ProcessKind.isClaude(source.details(claudePID), name: claude.name),
           claude.startTime <= serverStart + 1 {
            return .live(ClaudeSession(claudePID: claudePID, sessionID: sessionID, tty: claude.tty))
        }
        if let sessionID, !sessionID.isEmpty { return .ended(sessionID: sessionID) }
        return .other
    }

    /// A short name for the server: the command the agent ran, preferring the oldest
    /// non-shell process in the group ("npm run dev") over the worker that holds the port.
    func describe(_ info: ProcInfo) -> String {
        let tree = ProcessTree(source: source)
        let launcher = tree.ancestors(of: info.pid)
            .filter { $0.pgid == info.pgid && !ProcessKind.shells.contains($0.name) }
            .last
        for candidate in [launcher, info].compactMap({ $0 }) {
            if let args = source.details(candidate.pid)?.args?.arguments, !args.isEmpty {
                let text = Self.summarize(arguments: args)
                if !text.isEmpty { return text }
            }
        }
        return info.name
    }

    static func summarize(arguments: [String]) -> String {
        // A renamed process leaves its old argument slots behind as empty strings.
        var words = arguments.filter { !$0.isEmpty }
        guard let first = words.first else { return "" }
        if words.count == 1, first.contains(" ") {
            // Renamed via process.title, e.g. "npm exec next dev -p 3103".
            words = first.split(separator: " ").map(String.init)
        }
        words[0] = (words[0] as NSString).lastPathComponent
        let interpreter = words[0].lowercased()
        if ProcessKind.interpreters.contains(interpreter) || interpreter.hasPrefix("python") {
            words.removeFirst()
            if words.first == "-m" { words.removeFirst() }
        }
        if words.count >= 2, ["npm", "pnpm", "yarn", "bun"].contains(words[0]), ["exec", "x"].contains(words[1]) {
            words.removeFirst(2)
        }
        let text = words.map { $0.hasPrefix("/") ? ($0 as NSString).lastPathComponent : $0 }
            .joined(separator: " ")
        return text.count > 48 ? String(text.prefix(47)) + "…" : text
    }
}

struct ProcessTree {
    let source: ProcessSource

    /// Parents from nearest to furthest, stopping before launchd.
    func ancestors(of pid: pid_t) -> [ProcInfo] {
        var result: [ProcInfo] = []
        var current = source.processes[pid]?.ppid ?? 0
        while current > 1, let info = source.processes[current], result.count < 64 {
            result.append(info)
            current = info.ppid
        }
        return result
    }

    func group(_ pgid: pid_t) -> [ProcInfo] {
        source.processes.values.filter { $0.pgid == pgid }.sorted { $0.pid < $1.pid }
    }

    func descendants(of roots: [pid_t]) -> [ProcInfo] {
        var children: [pid_t: [ProcInfo]] = [:]
        for info in source.processes.values { children[info.ppid, default: []].append(info) }
        var result: [ProcInfo] = []
        var queue = roots
        var seen = Set(roots)
        while let next = queue.popLast() {
            for child in children[next] ?? [] where seen.insert(child.pid).inserted {
                result.append(child)
                queue.append(child.pid)
            }
        }
        return result
    }

    func ownershipCandidates(for info: ProcInfo) -> [pid_t] {
        var ordered = [info.pid] + ancestors(of: info.pid).map(\.pid)
        if info.pgid > 1 { ordered += group(info.pgid).map(\.pid) }
        var seen = Set<pid_t>()
        return ordered.filter { seen.insert($0).inserted }
    }
}

enum ProcessKind {
    /// Colima's own DNS and network ports: plumbing, even when a Claude session started Colima.
    static let alwaysHidden: Set<String> = ["limactl"]
    static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "dash", "-zsh", "-bash", "login"]
    static let interpreters: Set<String> = ["node", "bun", "deno", "ruby", "php", "java", "perl", "uv", "uvx"]

    static func isClaude(_ details: ProcDetails?, name: String) -> Bool {
        if name == "claude" { return true }
        if let path = details?.path {
            if path.contains("/claude/versions/") || (path as NSString).lastPathComponent == "claude" { return true }
        }
        if let argv0 = details?.args?.arguments.first, (argv0 as NSString).lastPathComponent == "claude" { return true }
        return false
    }

    static func isColimaForward(name: String, arguments: [String]) -> Bool {
        name == "ssh" && arguments.contains { $0.contains("/.colima/") || $0.contains("/.lima/") }
    }

    /// Listeners that belong to macOS or to desktop apps rather than to anything you started:
    /// AirPlay, Continuity, Discord, Colima's own control ports.
    static func isSystemListener(path: String?, name: String) -> Bool {
        guard let path else { return false }
        for prefix in ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/", "/sbin/"] where path.hasPrefix(prefix) {
            return true
        }
        let home = NSHomeDirectory()
        for apps in ["/Applications/", home + "/Applications/"] where path.hasPrefix(apps) {
            // Developer tools inside Xcode (its bundled Python, for one) are fair game.
            return !path.contains(".app/Contents/Developer/")
        }
        return false
    }
}
