import Foundation

/// The live process table for one scan. Details are read lazily and kept between scans,
/// keyed by PID and start time, so a steady system costs one libproc call per process.
final class LiveProcesses: ProcessSource {
    let processes: [pid_t: ProcInfo]
    private let cache: DetailCache

    init(processes: [pid_t: ProcInfo], cache: DetailCache) {
        self.processes = processes
        self.cache = cache
    }

    func details(_ pid: pid_t) -> ProcDetails? {
        guard let info = processes[pid] else { return nil }
        return cache.details(for: ProcRef(pid: pid, startTime: info.startTime))
    }
}

final class DetailCache: @unchecked Sendable {
    private var entries: [ProcRef: ProcDetails] = [:]
    private let lock = NSLock()

    func details(for ref: ProcRef) -> ProcDetails {
        lock.lock(); defer { lock.unlock() }
        if let cached = entries[ref] { return cached }
        let details = ProcDetails(path: LibProc.path(ref.pid), args: LibProc.args(ref.pid), cwd: LibProc.cwd(ref.pid))
        entries[ref] = details
        return details
    }

    func keep(only processes: [pid_t: ProcInfo]) {
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { processes[$0.key.pid]?.startTime == $0.key.startTime }
    }
}

/// Finds every TCP port the current user is listening on and resolves it into rows.
final class PortScanner: @unchecked Sendable {
    private let cache = DetailCache()
    let registry: Registry

    init(registry: Registry = .standard) {
        self.registry = registry
    }

    func snapshot() -> (source: LiveProcesses, listeners: [Listener]) {
        var processes: [pid_t: ProcInfo] = [:]
        for pid in LibProc.allPIDs() {
            if let info = LibProc.info(pid) { processes[pid] = info }
        }
        cache.keep(only: processes)

        let uid = getuid()
        var listeners: [Listener] = []
        for info in processes.values where info.uid == uid {
            for socket in LibProc.listeningPorts(info.pid) {
                listeners.append(Listener(pid: info.pid, port: socket.port, address: socket.address))
            }
        }
        return (LiveProcesses(processes: processes, cache: cache), listeners)
    }

    func scan() -> (servers: [Server], source: LiveProcesses) {
        let (source, listeners) = snapshot()
        registry.prune(processes: source.processes)
        let resolver = Resolver(source: source, registry: registry.load())
        return (resolver.servers(from: listeners), source)
    }
}
