import AppKit
import Observation

struct SessionGroup: Identifiable, Hashable {
    let session: ClaudeSession
    let title: String
    let servers: [Server]
    var id: pid_t { session.claudePID }
}

/// Everything the menu and the pinned window show, refreshed every two seconds.
@MainActor @Observable
final class Store {
    private(set) var servers: [Server] = []
    private(set) var sessionTitles: [String: String] = [:]
    private(set) var stopping: Set<String> = []
    private(set) var message: String?
    private(set) var needsAutomationPermission = false

    static let defaultResumeCommand = "claude --resume {id}"

    @ObservationIgnored private let scanner = PortScanner()
    @ObservationIgnored private let sessions = SessionDirectory()
    @ObservationIgnored private let scanQueue = DispatchQueue(label: "uk.lbsi.Localhosts.scan", qos: .utility)
    @ObservationIgnored private var lastSource: LiveProcesses?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var scanning = false
    @ObservationIgnored private var messageClear: DispatchWorkItem?

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        let scanner = scanner, sessions = sessions
        scanQueue.async { [weak self] in
            let (servers, source) = scanner.scan()
            var titles: [String: String] = [:]
            for id in Set(servers.compactMap(\.sessionID)) {
                if let title = sessions.info(for: id)?.title { titles[id] = title }
            }
            Task { @MainActor in
                self?.apply(servers: servers, titles: titles, source: source)
            }
        }
    }

    private func apply(servers: [Server], titles: [String: String], source: LiveProcesses) {
        scanning = false
        lastSource = source
        if self.servers != servers { self.servers = servers }
        if sessionTitles != titles { sessionTitles = titles }
    }

    #if DEBUG
    /// Shows made-up servers instead of scanning (see Demo).
    func showDemo(servers: [Server], titles: [String: String], permissionBanner: Bool) {
        self.servers = servers
        sessionTitles = titles
        needsAutomationPermission = permissionBanner
    }
    #endif

    // MARK: sections

    var liveGroups: [SessionGroup] {
        var bySession: [ClaudeSession: [Server]] = [:]
        for server in servers {
            if case .live(let session) = server.owner { bySession[session, default: []].append(server) }
        }
        return bySession.map { session, servers in
            SessionGroup(session: session, title: title(for: session), servers: servers)
        }
        .sorted { ($0.session.tty ?? "~", $0.session.claudePID) < ($1.session.tty ?? "~", $1.session.claudePID) }
    }

    var endedServers: [Server] {
        servers.filter { if case .ended = $0.owner { return true } else { return false } }
    }

    var otherServers: [Server] {
        servers.filter { $0.owner == .other }
    }

    /// The menu bar count: servers Claude started, live or not.
    var claudeCount: Int { servers.count - otherServers.count }

    func title(for session: ClaudeSession) -> String {
        session.sessionID.flatMap { sessionTitles[$0] } ?? "Claude session"
    }

    func endedTitle(for server: Server) -> String? {
        server.sessionID.flatMap { sessionTitles[$0] }
    }

    // MARK: actions

    func open(_ server: Server) {
        NSWorkspace.shared.open(server.url)
    }

    func goToTerminal(_ server: Server) {
        guard case .live(let session) = server.owner, let tty = session.tty else {
            show("That Claude session isn't running in a Terminal tab.")
            return
        }
        handle(TerminalBridge.focus(tty: tty), missing: "Couldn't find the Terminal tab for \(tty).")
    }

    func resume(_ server: Server) {
        guard case .ended(let id) = server.owner else { return }
        let template = UserDefaults.standard.string(forKey: "resumeCommand") ?? Self.defaultResumeCommand
        let command = template.replacingOccurrences(of: "{id}", with: id)
        let folder = sessions.info(for: id, maxAge: .infinity)?.cwd ?? NSHomeDirectory()
        handle(TerminalBridge.run(command: command, in: folder), missing: "")
    }

    func stop(_ server: Server) {
        guard let source = lastSource, !stopping.contains(server.id) else { return }
        stopping.insert(server.id)
        let plan = Stopper.plan(for: server, source: source)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Stopper.execute(plan)
            Task { @MainActor in
                self?.finishStop(server.id, result: result)
            }
        }
    }

    /// Keeps the spinner up until the next scan has dropped the server, so the row doesn't flash back.
    private func finishStop(_ id: String, result: StopResult) {
        if case .failed(let reason) = result { show(reason) }
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated { _ = self?.stopping.remove(id) }
        }
    }

    func openAutomationSettings() {
        NSWorkspace.shared.open(TerminalBridge.automationSettings)
    }

    func dismissMessage() { message = nil }

    private func handle(_ outcome: TerminalBridge.Outcome, missing: String) {
        switch outcome {
        case .done: needsAutomationPermission = false
        case .tabNotFound: show(missing)
        case .notAuthorised: needsAutomationPermission = true
        case .failed(let text): show(text)
        }
    }

    private func show(_ text: String) {
        message = text
        messageClear?.cancel()
        let clear = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.message = nil } }
        messageClear = clear
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: clear)
    }
}
