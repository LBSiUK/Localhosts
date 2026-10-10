#if DEBUG
import AppKit

/// Made-up servers for screenshots, so no real projects or folders show up in them.
/// Debug builds only: `Localhosts -demo YES`, plus any of
///   -demoScreen NAME        put the windows on the display whose name contains NAME
///   -demoAppearance light   or dark
///   -demoBanner YES         show the Terminal permission banner
///   -demoMenu YES           open the menu bar dropdown
///   -demoSettings YES       open the Settings window
///   -otherExpanded YES      open the Other section
enum Demo {
    static let openSettings = Notification.Name("LocalhostsDemoOpenSettings")

    private static let defaults = UserDefaults.standard

    static var isOn: Bool { defaults.bool(forKey: "demo") }

    @MainActor
    static func start(store: Store, pin: PinController) {
        switch defaults.string(forKey: "demoAppearance") {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        store.showDemo(servers: servers(), titles: titles, permissionBanner: defaults.bool(forKey: "demoBanner"))

        let frame = screen.visibleFrame
        pin.showForDemo(topLeft: NSPoint(x: frame.minX + 60, y: frame.maxY - 60))

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if defaults.bool(forKey: "demoMenu") { clickStatusItem() }
            if defaults.bool(forKey: "demoSettings") {
                NotificationCenter.default.post(name: openSettings, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    let settings = NSApp.windows.first { $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }
                    settings?.setFrameTopLeftPoint(NSPoint(x: frame.minX + 520, y: frame.maxY - 60))
                    // Once the window is clicked to the front, leave the command field unselected.
                    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
                        MainActor.assumeIsolated { _ = settings?.makeFirstResponder(nil) }
                    }
                }
            }
        }
    }

    private static var screen: NSScreen {
        let name = defaults.string(forKey: "demoScreen") ?? ""
        return NSScreen.screens.first { !name.isEmpty && $0.localizedName.localizedCaseInsensitiveContains(name) }
            ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private static func clickStatusItem() {
        for window in NSApp.windows {
            if let button = statusButton(in: window.contentView) {
                button.performClick(nil)
                return
            }
        }
    }

    private static func statusButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        return view.subviews.lazy.compactMap(statusButton(in:)).first
    }

    // MARK: data

    private static let portfolio = ClaudeSession(claudePID: 41210, sessionID: "demo-portfolio", tty: "ttys002")
    private static let recipes = ClaudeSession(claudePID: 41877, sessionID: "demo-recipes", tty: "ttys005")

    private static let titles = [
        "demo-portfolio": "Portfolio site redesign",
        "demo-recipes": "Recipe API pagination",
        "demo-docs": "Docs search spike",
    ]

    private static func servers() -> [Server] {
        let now = Date().timeIntervalSince1970
        func server(_ port: UInt16, _ label: String, _ command: String, folder: String?, minutesAgo: Double,
                    owner: Owner, path: String = "/", launchd: String? = nil, docker: Bool = false) -> Server {
            Server(pid: pid_t(50000 + Int(port) % 9000), port: port, address: "127.0.0.1",
                   processName: String(command.split(separator: " ").first ?? ""), command: command,
                   cwd: folder.map { "/Users/demo/code/" + $0 }, startTime: now - minutesAgo * 60,
                   label: label, path: path, owner: owner, stopCommand: nil,
                   launchdLabel: launchd, isDockerForward: docker)
        }
        return [
            server(3000, "portfolio: Next.js dev server", "next dev", folder: "portfolio", minutesAgo: 42, owner: .live(portfolio)),
            server(6006, "portfolio: Storybook", "storybook dev -p 6006", folder: "portfolio", minutesAgo: 38, owner: .live(portfolio)),
            server(8000, "recipes: API docs", "uvicorn app.main:app --reload", folder: "recipes", minutesAgo: 72,
                   owner: .live(recipes), path: "/docs"),
            server(4321, "docs: Astro preview", "astro dev", folder: "docs", minutesAgo: 27 * 60,
                   owner: .ended(sessionID: "demo-docs")),
            server(5050, "dashboard.py", "python3 dashboard.py", folder: nil, minutesAgo: 3 * 24 * 60 + 240,
                   owner: .other, launchd: "com.example.dashboard"),
            server(8080, "http.server 8080", "python3 -m http.server 8080", folder: nil, minutesAgo: 5, owner: .other),
            server(8081, "Docker container (Colima)", "ssh -F colima/ssh.config lima-colima", folder: nil,
                   minutesAgo: 2 * 24 * 60, owner: .other, docker: true),
        ].sorted { $0.port < $1.port }
    }
}
#endif
