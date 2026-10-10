import Foundation

/// A process pinned to its start time, so a recycled PID is never signalled by mistake.
struct ProcRef: Hashable {
    let pid: pid_t
    let startTime: TimeInterval
}

enum StopPlan: Equatable {
    case signal([ProcRef])
    case command(String, cwd: String?)
    case refused(String)
}

enum StopResult: Equatable {
    case stopped
    case failed(String)
}

enum Stopper {
    /// Picks what to stop. Normally that is the server's whole process group (npm, node and the
    /// workers they spawned), plus anything those started in groups of their own. The group is
    /// skipped in favour of just the server and its children when it holds Claude, this app,
    /// an interactive shell or someone else's process.
    static func plan(for server: Server, source: ProcessSource,
                     ownPID: pid_t = getpid(), ownPGID: pid_t = getpgrp(), ownUID: uid_t = getuid()) -> StopPlan {
        if let command = server.stopCommand, !command.isEmpty {
            return .command(command, cwd: server.cwd)
        }
        if server.isDockerForward {
            return .refused("Colima forwards this port for a Docker container, and its process carries every container's ports. Register a stop command with `localhosts add \(server.port) --stop-cmd …`.")
        }
        guard let listener = source.processes[server.pid] else { return .refused("The server has already stopped.") }

        func killable(_ info: ProcInfo) -> Bool {
            info.pid > 1 && info.pid != ownPID && info.uid == ownUID
                && !ProcessKind.isClaude(source.details(info.pid), name: info.name)
        }
        guard killable(listener) else { return .refused("This process isn't yours to stop.") }

        let tree = ProcessTree(source: source)
        let group = tree.group(listener.pgid)
        let groupIsSafe = listener.pgid > 1 && listener.pgid != ownPGID && group.allSatisfy { info in
            killable(info) && !(ProcessKind.shells.contains(info.name) && info.tty != nil)
        }
        let roots = groupIsSafe ? group : [listener]
        var targets = roots
        for child in tree.descendants(of: roots.map(\.pid)) where killable(child) && !targets.contains(child) {
            targets.append(child)
        }
        return .signal(targets.map { ProcRef(pid: $0.pid, startTime: $0.startTime) }.sorted { $0.pid < $1.pid })
    }

    /// Sends SIGTERM, waits up to `grace` seconds, then SIGKILLs whatever is left.
    static func execute(_ plan: StopPlan, grace: TimeInterval = 3, isAlive: (ProcRef) -> Bool = Stopper.isAlive) -> StopResult {
        switch plan {
        case .refused(let reason):
            return .failed(reason)
        case .command(let command, let cwd):
            return run(command, cwd: cwd)
        case .signal(let refs):
            for ref in refs where isAlive(ref) { kill(ref.pid, SIGTERM) }
            if waitUntilGone(refs, timeout: grace, isAlive: isAlive) { return .stopped }
            for ref in refs where isAlive(ref) { kill(ref.pid, SIGKILL) }
            if waitUntilGone(refs, timeout: 2, isAlive: isAlive) { return .stopped }
            let left = refs.filter(isAlive).map { String($0.pid) }.joined(separator: ", ")
            return .failed("Still running after a forced stop (PID \(left)).")
        }
    }

    static func isAlive(_ ref: ProcRef) -> Bool {
        guard let info = LibProc.info(ref.pid) else { return false }
        return abs(info.startTime - ref.startTime) < 0.001
    }

    private static func waitUntilGone(_ refs: [ProcRef], timeout: TimeInterval, isAlive: (ProcRef) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !refs.contains(where: isAlive) { return true }
            usleep(100_000)
        } while Date() < deadline
        return !refs.contains(where: isAlive)
    }

    private static func run(_ command: String, cwd: String?) -> StopResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        if let cwd { process.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return .failed("Couldn't run the stop command: \(error.localizedDescription)") }

        let deadline = Date().addingTimeInterval(60)
        while process.isRunning, Date() < deadline { usleep(100_000) }
        if process.isRunning {
            process.terminate()
            return .failed("The stop command was still running after a minute.")
        }
        if process.terminationStatus == 0 { return .stopped }
        let text = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed("The stop command failed (exit \(process.terminationStatus)). \(text.suffix(200))")
    }
}
