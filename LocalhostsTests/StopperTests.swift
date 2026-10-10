import Foundation
import Testing

struct StopperTests {
    private func server(_ source: FakeSource, pid: pid_t, port: UInt16, registry: [RegistryEntry] = []) -> Server {
        Resolver(source: source, registry: registry, ownPID: 1).server(for: Listener(pid: pid, port: port, address: "*"))!
    }

    private func pids(_ plan: StopPlan) -> [pid_t] {
        if case .signal(let refs) = plan { return refs.map(\.pid) }
        return []
    }

    @Test func stopsTheWholeGroupAndItsStrays() {
        var source = FakeSource.withClaude()
        source.add(700, parent: 1, group: 690, name: "npm exec next dev", env: claudeEnv)
        source.add(701, parent: 700, group: 690, name: "node", env: claudeEnv)
        source.add(702, parent: 701, group: 690, name: "next-server (v15.5.24)")
        // A helper that moved itself into its own group still goes.
        source.add(703, parent: 702, group: 703, name: "esbuild")
        let plan = Stopper.plan(for: server(source, pid: 702, port: 3103), source: source, ownPID: 1, ownPGID: 1, ownUID: 501)
        #expect(pids(plan) == [700, 701, 702, 703])
    }

    @Test func neverSignalsAGroupHoldingClaude() {
        var source = FakeSource.withClaude()
        // Same group as Claude (pgid 500): only the server and its children may go.
        source.add(600, parent: 500, group: 500, name: "Python", env: claudeEnv)
        source.add(601, parent: 600, group: 500, name: "worker")
        let plan = Stopper.plan(for: server(source, pid: 600, port: 8000), source: source, ownPID: 1, ownPGID: 1, ownUID: 501)
        #expect(pids(plan) == [600, 601])
    }

    @Test func neverSignalsAGroupHoldingAnInteractiveShell() {
        var source = FakeSource()
        source.add(450, parent: 1, group: 450, name: "-zsh", tty: "ttys002")
        source.add(460, parent: 450, group: 450, name: "node")
        let plan = Stopper.plan(for: server(source, pid: 460, port: 3000), source: source, ownPID: 1, ownPGID: 1, ownUID: 501)
        #expect(pids(plan) == [460])
    }

    @Test func neverSignalsItsOwnGroup() {
        var source = FakeSource()
        source.add(600, parent: 1, group: 77, name: "Python")
        source.add(601, parent: 1, group: 77, name: "other")
        let plan = Stopper.plan(for: server(source, pid: 600, port: 8000), source: source, ownPID: 1, ownPGID: 77, ownUID: 501)
        #expect(pids(plan) == [600])
    }

    @Test func refusesSomeoneElsesProcess() {
        var source = FakeSource()
        source.add(600, parent: 1, group: 600, name: "postgres", uid: 0)
        let plan = Stopper.plan(for: server(source, pid: 600, port: 5432), source: source, ownPID: 1, ownPGID: 1, ownUID: 501)
        guard case .refused = plan else { Issue.record("expected a refusal, got \(plan)"); return }
    }

    @Test func dockerForwardUsesItsStopCommandOrIsRefused() {
        var source = FakeSource()
        source.add(900, parent: 1, group: 900, name: "ssh", path: "/usr/bin/ssh",
                   args: ["ssh", "-F", "/Users/me/.colima/_lima/colima/ssh.config", "lima-colima"])
        let bare = server(source, pid: 900, port: 8081)
        guard case .refused = Stopper.plan(for: bare, source: source, ownPID: 1, ownPGID: 1, ownUID: 501) else {
            Issue.record("expected a refusal"); return
        }
        let entry = RegistryEntry(port: 8081, pid: 900, pgid: 900, processStart: 1000, label: nil, path: nil,
                                  stopCommand: "docker compose stop api", cwd: "/Users/me/code/suds",
                                  sessionID: nil, claudePID: nil, registeredAt: Date())
        let registered = server(source, pid: 900, port: 8081, registry: [entry])
        #expect(Stopper.plan(for: registered, source: source, ownPID: 1, ownPGID: 1, ownUID: 501)
                == .command("docker compose stop api", cwd: "/Users/me/code/suds"))
    }

    /// The real thing: start a server, find it with the live scanner, stop it.
    @Test func stopsARealServer() throws {
        let port = UInt16.random(in: 49_000...59_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-m", "http.server", String(port), "--bind", "127.0.0.1"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let registry = Registry(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let scanner = PortScanner(registry: registry)
        var found: Server?
        for _ in 0..<50 where found == nil {
            found = scanner.scan().servers.first { $0.port == port }
            if found == nil { usleep(100_000) }
        }
        let server = try #require(found)
        #expect(server.label == "http.server \(port) --bind 127.0.0.1")

        let (_, source) = scanner.scan()
        let plan = Stopper.plan(for: server, source: source)
        // The test runner shares the server's process group, so only the server itself is targeted.
        #expect(pids(plan) == [server.pid])
        #expect(Stopper.execute(plan) == .stopped)
        #expect(scanner.scan().servers.contains { $0.port == port } == false)
    }
}
