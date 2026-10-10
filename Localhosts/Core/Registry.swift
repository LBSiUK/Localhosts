import Foundation

/// What an agent told us about a server it started: a readable label, the page worth opening,
/// and how to stop it when killing the process is the wrong move (Docker containers).
struct RegistryEntry: Codable, Equatable {
    var port: UInt16
    var pid: Int32
    var pgid: Int32
    var processStart: TimeInterval
    var label: String?
    var path: String?
    var stopCommand: String?
    var cwd: String?
    var sessionID: String?
    var claudePID: Int32?
    var registeredAt: Date

    /// The same process, or a restarted worker in the same process group (Next.js and Vite
    /// restart their worker when the config changes).
    func matches(_ listener: Listener, info: ProcInfo) -> Bool {
        guard listener.port == port else { return false }
        if info.pid == pid, abs(info.startTime - processStart) < 1 { return true }
        return pgid > 1 && info.pgid == pgid
    }

    var normalisedPath: String {
        guard let path, !path.isEmpty else { return "/" }
        return path.hasPrefix("/") ? path : "/" + path
    }
}

/// One small JSON file per registered port, so the CLI and the app never fight over a shared file.
struct Registry {
    let directory: URL

    static var standard: Registry {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return Registry(directory: support.appendingPathComponent("Localhosts/servers", isDirectory: true))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func load() -> [RegistryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? Self.decoder.decode(RegistryEntry.self, from: data)
        }
    }

    func save(_ entry: RegistryEntry) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(entry).write(to: file(for: entry.port), options: .atomic)
    }

    func remove(port: UInt16) {
        try? FileManager.default.removeItem(at: file(for: port))
    }

    /// Forgets entries whose process and process group have both gone.
    func prune(processes: [pid_t: ProcInfo]) {
        let groups = Set(processes.values.map(\.pgid))
        for entry in load() {
            let processAlive = processes[entry.pid].map { abs($0.startTime - entry.processStart) < 1 } ?? false
            if !processAlive, !(entry.pgid > 1 && groups.contains(entry.pgid)) {
                remove(port: entry.port)
            }
        }
    }

    private func file(for port: UInt16) -> URL {
        directory.appendingPathComponent("\(port).json")
    }
}
