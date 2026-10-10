import Foundation

/// The basic facts about one process, cheap enough to read for every process on each scan.
struct ProcInfo: Hashable {
    let pid: pid_t
    let ppid: pid_t
    let pgid: pid_t
    let uid: uid_t
    let name: String
    let startTime: TimeInterval
    /// "ttys007", or nil for processes with no terminal.
    let tty: String?
}

/// The slower facts about a process, read only for processes near a listening socket.
struct ProcDetails {
    var path: String?
    var args: ProcArgs?
    var cwd: String?

    var environment: [String: String] { args?.environment ?? [:] }
}

/// A process listening on a TCP port.
struct Listener: Hashable {
    let pid: pid_t
    let port: UInt16
    let address: String
}

/// Where the app gets process facts from. Tests supply a fake table.
protocol ProcessSource {
    var processes: [pid_t: ProcInfo] { get }
    func details(_ pid: pid_t) -> ProcDetails?
}

struct ClaudeSession: Hashable {
    let claudePID: pid_t
    let sessionID: String?
    let tty: String?
}

enum Owner: Hashable {
    /// Started by a Claude session that is still running.
    case live(ClaudeSession)
    /// Started by a Claude session that has since closed.
    case ended(sessionID: String)
    /// Not started by Claude.
    case other
}

/// One row in the list: a listening port, who owns it and how to stop it.
struct Server: Identifiable, Hashable {
    let pid: pid_t
    let port: UInt16
    let address: String
    let processName: String
    let command: String
    let cwd: String?
    let startTime: TimeInterval
    var label: String
    var path: String
    var owner: Owner
    var stopCommand: String?
    /// The launchd job that keeps this process alive, if any. Stopping it only restarts it.
    var launchdLabel: String?
    /// A port Colima forwards for a Docker container. Its process carries every container's ports.
    var isDockerForward: Bool

    var id: String { "\(pid):\(port)" }

    var url: URL { URL(string: "http://localhost:\(port)\(path)") ?? URL(string: "http://localhost:\(port)/")! }

    var folderName: String? {
        guard let cwd, cwd != NSHomeDirectory(), cwd != "/" else { return nil }
        return (cwd as NSString).lastPathComponent
    }

    /// Why Stop is unavailable, when it is.
    var stopRefusal: String? {
        guard isDockerForward, stopCommand == nil else { return nil }
        return "Colima forwards this port for a Docker container. Stopping it would cut every container's ports, so ask the agent to register a stop command."
    }

    var sessionID: String? {
        switch owner {
        case .live(let session): return session.sessionID
        case .ended(let id): return id
        case .other: return nil
        }
    }
}

enum Uptime {
    static func text(since start: TimeInterval, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince1970 - start))
        let minutes = seconds / 60, hours = minutes / 60, days = hours / 24
        if days > 0 { return "\(days)d \(hours % 24)h" }
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        if minutes > 0 { return "\(minutes)m" }
        return "just now"
    }
}
