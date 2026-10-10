import Foundation

struct SessionInfo: Equatable {
    var title: String?
    var cwd: String?
}

/// Reads Claude Code's session transcripts in ~/.claude/projects for a session's title
/// (the one Claude shows in the Terminal tab) and the folder it was started in.
final class SessionDirectory: @unchecked Sendable {
    let projectsRoot: URL
    private var files: [String: URL] = [:]
    private var cache: [String: (info: SessionInfo, fetched: Date)] = [:]
    private let lock = NSLock()

    init(projectsRoot: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/projects")) {
        self.projectsRoot = projectsRoot
    }

    func info(for sessionID: String, maxAge: TimeInterval = 30) -> SessionInfo? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[sessionID], Date().timeIntervalSince(cached.fetched) < maxAge { return cached.info }
        guard let file = transcript(for: sessionID) else { return nil }
        let head = Self.read(file, fromEnd: false, bytes: 256 * 1024)
        let tail = Self.read(file, fromEnd: true, bytes: 2 * 1024 * 1024)
        let info = SessionInfo(title: Self.title(inJSONL: tail) ?? Self.title(inJSONL: head),
                               cwd: Self.cwd(inJSONL: head) ?? Self.cwd(inJSONL: tail))
        cache[sessionID] = (info, Date())
        return info
    }

    private func transcript(for sessionID: String) -> URL? {
        if let known = files[sessionID], FileManager.default.fileExists(atPath: known.path) { return known }
        let name = sessionID + ".jsonl"
        let folders = (try? FileManager.default.contentsOfDirectory(at: projectsRoot, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let candidate = folder.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) {
                files[sessionID] = candidate
                return candidate
            }
        }
        return nil
    }

    /// The newest title in the text: a name you gave the session wins over Claude's own.
    static func title(inJSONL text: String) -> String? {
        var aiTitle: String?
        for line in text.split(separator: "\n").reversed() {
            if line.contains("\"custom-title\""), let object = parse(line), let title = object["customTitle"] as? String, !title.isEmpty {
                return title
            }
            if aiTitle == nil, line.contains("\"ai-title\""), let object = parse(line), let title = object["aiTitle"] as? String, !title.isEmpty {
                aiTitle = title
            }
        }
        return aiTitle
    }

    static func cwd(inJSONL text: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("\"cwd\"") {
            if let object = parse(line), let cwd = object["cwd"] as? String, !cwd.isEmpty { return cwd }
        }
        return nil
    }

    private static func parse(_ line: Substring) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Reads a slice of the file. A slice that starts mid-line loses that line, which is fine:
    /// the callers only look for whole JSON lines.
    private static func read(_ url: URL, fromEnd: Bool, bytes: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = fromEnd ? UInt64(max(0, Int64(size) - Int64(bytes))) : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.read(upToCount: bytes)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
