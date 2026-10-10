import Foundation
import Testing

struct ResolverTests {
    @Test func backgroundTaskBelongsToItsLiveSession() {
        var source = FakeSource.withClaude()
        source.add(600, parent: 500, group: 600, name: "Python", start: 2000,
                   args: ["/opt/homebrew/bin/python3", "-m", "http.server", "8765"], env: claudeEnv, cwd: "/Users/me/code/site")
        let server = Resolver(source: source, registry: []).server(for: Listener(pid: 600, port: 8765, address: "*"))

        #expect(server?.owner == .live(ClaudeSession(claudePID: 500, sessionID: "abc-123", tty: "ttys007")))
        #expect(server?.label == "http.server 8765")
        #expect(server?.folderName == "site")
    }

    @Test func renamedNextServerIsTracedThroughItsParent() {
        var source = FakeSource.withClaude()
        // npm and next-server overwrite their own argv and environment; the middle node process keeps it.
        source.add(700, parent: 1, group: 690, name: "npm exec next dev -p 3103", start: 2000,
                   args: ["npm exec next dev -p 3103"])
        source.add(701, parent: 700, group: 690, name: "node", start: 2001, env: claudeEnv)
        source.add(702, parent: 701, group: 690, name: "next-server (v15.5.24)", start: 2002,
                   args: ["next-server (v15.5.24)"])
        let server = Resolver(source: source, registry: []).server(for: Listener(pid: 702, port: 3103, address: "*"))

        #expect(server?.owner == .live(ClaudeSession(claudePID: 500, sessionID: "abc-123", tty: "ttys007")))
        #expect(server?.label == "next dev -p 3103")
    }

    @Test func serverOutlivingItsSessionIsEnded() {
        var source = FakeSource()
        source.add(600, parent: 1, group: 600, name: "Python", start: 2000, env: claudeEnv)
        let server = Resolver(source: source, registry: []).server(for: Listener(pid: 600, port: 8787, address: "127.0.0.1"))
        #expect(server?.owner == .ended(sessionID: "abc-123"))
    }

    @Test func recycledClaudePIDDoesNotCount() {
        var source = FakeSource()
        // PID 500 now belongs to something else that started after the server.
        source.add(500, parent: 1, group: 500, name: "mdworker", start: 5000, tty: "ttys001")
        source.add(600, parent: 1, group: 600, name: "Python", start: 2000, env: claudeEnv)
        let server = Resolver(source: source, registry: []).server(for: Listener(pid: 600, port: 8000, address: "*"))
        #expect(server?.owner == .ended(sessionID: "abc-123"))
    }

    @Test func newerClaudeOnTheSamePIDDoesNotCount() {
        var source = FakeSource()
        source.add(500, parent: 1, group: 500, name: "claude", start: 9000, tty: "ttys003")
        source.add(600, parent: 1, group: 600, name: "Python", start: 2000, env: claudeEnv)
        let server = Resolver(source: source, registry: []).server(for: Listener(pid: 600, port: 8000, address: "*"))
        #expect(server?.owner == .ended(sessionID: "abc-123"))
    }

    @Test func claudeItselfIsNeverListed() {
        let source = FakeSource.withClaude()
        #expect(Resolver(source: source, registry: []).server(for: Listener(pid: 500, port: 45000, address: "127.0.0.1")) == nil)
    }

    @Test(arguments: [
        "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
        "/usr/libexec/rapportd",
        "/Applications/Discord.app/Contents/MacOS/Discord",
    ])
    func systemAndDesktopAppListenersAreHidden(path: String) {
        var source = FakeSource()
        source.add(800, parent: 1, group: 800, name: "x", path: path)
        #expect(Resolver(source: source, registry: []).server(for: Listener(pid: 800, port: 7000, address: "*")) == nil)
    }

    @Test func colimaPlumbingIsHiddenEvenWhenClaudeStartedIt() {
        var source = FakeSource.withClaude()
        source.add(950, parent: 1, group: 950, name: "limactl", start: 2000, path: "/opt/homebrew/bin/limactl", env: claudeEnv)
        #expect(Resolver(source: source, registry: []).server(for: Listener(pid: 950, port: 53, address: "*")) == nil)
    }

    @Test func userServersShowAsOther() {
        var source = FakeSource()
        let xcodePython = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python"
        source.add(810, parent: 1, group: 810, name: "Python", path: xcodePython,
                   args: ["Python", "server.py"], env: ["XPC_SERVICE_NAME": "com.example.dashboard"])
        let server = Resolver(source: source, registry: []).server(for: Listener(pid: 810, port: 8091, address: "*"))
        #expect(server?.owner == .other)
        #expect(server?.launchdLabel == "com.example.dashboard")
    }

    @Test func registeredLabelPathAndSessionApply() {
        var source = FakeSource.withClaude()
        // Colima's ssh forward: no Claude environment, so only the registration links it to the session.
        source.add(900, parent: 1, group: 900, name: "ssh", start: 3000,
                   path: "/usr/bin/ssh", args: ["ssh", "-F", "/Users/me/.colima/_lima/colima/ssh.config", "lima-colima"])
        let entry = RegistryEntry(port: 8081, pid: 900, pgid: 900, processStart: 3000, label: "suds api (docker)",
                                  path: "health", stopCommand: "docker compose stop api", cwd: "/Users/me/code/suds",
                                  sessionID: "abc-123", claudePID: 500, registeredAt: Date())
        let server = Resolver(source: source, registry: [entry]).server(for: Listener(pid: 900, port: 8081, address: "*"))

        #expect(server?.label == "suds api (docker)")
        #expect(server?.url.absoluteString == "http://localhost:8081/health")
        #expect(server?.owner == .live(ClaudeSession(claudePID: 500, sessionID: "abc-123", tty: "ttys007")))
        #expect(server?.isDockerForward == true)
        #expect(server?.stopRefusal == nil)
    }

    @Test func unregisteredDockerForwardCannotBeStopped() {
        var source = FakeSource()
        source.add(900, parent: 1, group: 900, name: "ssh", path: "/usr/bin/ssh",
                   args: ["ssh", "-F", "/Users/me/.colima/_lima/colima/ssh.config", "lima-colima"])
        let server = Resolver(source: source, registry: []).server(for: Listener(pid: 900, port: 8081, address: "*"))
        #expect(server?.label == "Docker container (Colima)")
        #expect(server?.stopRefusal != nil)
    }

    @Test func registrationFollowsARestartedWorkerInTheSameGroup() {
        var source = FakeSource()
        source.add(705, parent: 1, group: 690, name: "node", start: 4000)
        let entry = RegistryEntry(port: 5173, pid: 702, pgid: 690, processStart: 2002, label: "vite", path: nil,
                                  stopCommand: nil, cwd: nil, sessionID: nil, claudePID: nil, registeredAt: Date())
        let server = Resolver(source: source, registry: [entry]).server(for: Listener(pid: 705, port: 5173, address: "*"))
        #expect(server?.label == "vite")
    }

    @Test(arguments: [
        (["/opt/homebrew/bin/python3", "-m", "http.server", "8765"], "http.server 8765"),
        (["npm exec next dev -p 3103"], "next dev -p 3103"),
        (["node", "/Users/me/app/node_modules/.bin/vite", "--port", "5173"], "vite --port 5173"),
        (["/Users/me/flamenco/manager/flamenco-manager"], "flamenco-manager"),
        (["next-server (v15.5.24)"], "next-server (v15.5.24)"),
        (["npm exec next dev -p 3101", "", "", "", ""], "next dev -p 3101"),
    ])
    func summarisesCommands(arguments: [String], expected: String) {
        #expect(Resolver.summarize(arguments: arguments) == expected)
    }
}
