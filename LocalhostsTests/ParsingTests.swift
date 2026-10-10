import Foundation
import Testing

struct ParsingTests {
    @Test func parsesArgumentsAndEnvironment() {
        let buffer = procArgsBuffer(executable: "/usr/bin/python3",
                                    arguments: ["python3", "-m", "http.server"],
                                    environment: ["CLAUDE_PID=500", "PATH=/usr/bin:/bin", "EMPTY="])
        let parsed = ProcArgs.parse(buffer)
        #expect(parsed?.executable == "/usr/bin/python3")
        #expect(parsed?.arguments == ["python3", "-m", "http.server"])
        #expect(parsed?.environment == ["CLAUDE_PID": "500", "PATH": "/usr/bin:/bin", "EMPTY": ""])
    }

    @Test func survivesAWipedEnvironment() {
        // What a process that set process.title looks like: one argument, then nothing.
        let buffer = procArgsBuffer(executable: "/opt/homebrew/bin/node", arguments: ["next-server (v15.5.24)"], environment: [])
        let parsed = ProcArgs.parse(buffer)
        #expect(parsed?.arguments == ["next-server (v15.5.24)"])
        #expect(parsed?.environment.isEmpty == true)
    }

    @Test func rejectsGarbage() {
        #expect(ProcArgs.parse([1, 2]) == nil)
        #expect(ProcArgs.parse([255, 255, 255, 255, 0]) == nil)
    }

    @Test func readsTheLiveEnvironmentOfThisProcess() {
        let parsed = LibProc.args(getpid())
        #expect(parsed?.environment["HOME"] == NSHomeDirectory())
    }

    @Test func customTitleBeatsAITitle() {
        let jsonl = """
        {"type":"ai-title","aiTitle":"First guess","sessionId":"s"}
        {"type":"custom-title","customTitle":"My name for it","sessionId":"s"}
        {"type":"ai-title","aiTitle":"Later guess","sessionId":"s"}
        """
        #expect(SessionDirectory.title(inJSONL: jsonl) == "My name for it")
        #expect(SessionDirectory.title(inJSONL: "{\"type\":\"ai-title\",\"aiTitle\":\"Only\"}\n") == "Only")
    }

    @Test func findsTheSessionFolder() {
        let jsonl = """
        {"type":"mode","mode":"normal"}
        {"parentUuid":null,"cwd":"/Users/me/code/site","sessionId":"s"}
        """
        #expect(SessionDirectory.cwd(inJSONL: jsonl) == "/Users/me/code/site")
    }

    @Test func readsTitleAndFolderFromATranscriptFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("-Users-me")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try """
        {"cwd":"/Users/me","sessionId":"s1"}
        {"type":"ai-title","aiTitle":"Localhost manager desktop app","sessionId":"s1"}
        """.write(to: project.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)

        let info = SessionDirectory(projectsRoot: root).info(for: "s1")
        #expect(info == SessionInfo(title: "Localhost manager desktop app", cwd: "/Users/me"))
        #expect(SessionDirectory(projectsRoot: root).info(for: "missing") == nil)
    }

    @Test(arguments: [
        ("5173", UInt16(5173), String?.none),
        ("http://localhost:3000/admin?tab=2", 3000, "/admin?tab=2"),
        ("127.0.0.1:8765/", 8765, nil),
    ])
    func parsesCLITargets(text: String, port: UInt16, path: String?) {
        let parsed = CLI.parseTarget(text)
        #expect(parsed?.port == port)
        #expect(parsed?.path == path)
    }

    @Test func rejectsRemoteURLs() {
        #expect(CLI.parseTarget("https://example.com:8080/") == nil)
    }

    @Test func registryRoundTripsAndPrunes() throws {
        let registry = Registry(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let entry = RegistryEntry(port: 5173, pid: 702, pgid: 690, processStart: 2002, label: "vite", path: "/app",
                                  stopCommand: nil, cwd: "/tmp", sessionID: "abc", claudePID: 500,
                                  registeredAt: Date(timeIntervalSince1970: 1_700_000_000))
        try registry.save(entry)
        #expect(registry.load() == [entry])

        let alive = [pid_t(705): ProcInfo(pid: 705, ppid: 1, pgid: 690, uid: 501, name: "node", startTime: 9, tty: nil)]
        registry.prune(processes: alive)
        #expect(registry.load().count == 1)
        registry.prune(processes: [:])
        #expect(registry.load().isEmpty)
    }

    @Test func uptimeReadsNaturally() {
        let now = Date(timeIntervalSince1970: 100_000)
        #expect(Uptime.text(since: 100_000 - 20, now: now) == "just now")
        #expect(Uptime.text(since: 100_000 - 300, now: now) == "5m")
        #expect(Uptime.text(since: 100_000 - 7_500, now: now) == "2h 5m")
        #expect(Uptime.text(since: 100_000 - 90_000, now: now) == "1d 1h")
    }
}
