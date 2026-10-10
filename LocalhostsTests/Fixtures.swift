import Foundation

struct FakeSource: ProcessSource {
    var processes: [pid_t: ProcInfo] = [:]
    var detailsByPID: [pid_t: ProcDetails] = [:]

    func details(_ pid: pid_t) -> ProcDetails? { detailsByPID[pid] }

    mutating func add(_ pid: pid_t, parent: pid_t, group: pid_t, name: String, start: TimeInterval = 1000,
                      tty: String? = nil, uid: uid_t = 501, path: String? = nil, args: [String]? = nil,
                      env: [String: String] = [:], cwd: String? = nil) {
        processes[pid] = ProcInfo(pid: pid, ppid: parent, pgid: group, uid: uid, name: name, startTime: start, tty: tty)
        let arguments = args ?? [name]
        detailsByPID[pid] = ProcDetails(path: path ?? "/usr/local/bin/\(name)",
                                        args: ProcArgs(executable: path ?? name, arguments: arguments, environment: env),
                                        cwd: cwd)
    }

    /// A Claude session in ttys007 (pid 500), started before anything else.
    static func withClaude() -> FakeSource {
        var source = FakeSource()
        source.add(400, parent: 1, group: 400, name: "login", tty: "ttys007", uid: 0)
        source.add(450, parent: 400, group: 450, name: "-zsh", tty: "ttys007")
        source.add(500, parent: 450, group: 500, name: "claude", start: 100, tty: "ttys007",
                   path: "/Users/me/.local/share/claude/versions/2.1.295", args: ["claude", "--dangerously-skip-permissions"])
        return source
    }
}

let claudeEnv = ["CLAUDE_PID": "500", "CLAUDE_CODE_SESSION_ID": "abc-123", "XPC_SERVICE_NAME": "0"]

func procArgsBuffer(executable: String, arguments: [String], environment: [String]) -> [UInt8] {
    var bytes = withUnsafeBytes(of: Int32(arguments.count)) { Array($0) }
    bytes += Array(executable.utf8) + [0, 0, 0, 0]
    for argument in arguments { bytes += Array(argument.utf8) + [0] }
    for variable in environment { bytes += Array(variable.utf8) + [0] }
    bytes += [0, 0, 0]
    return bytes
}
