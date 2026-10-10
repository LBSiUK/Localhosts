import Foundation

/// `localhosts`: the command agents run. Lives in the app binary; ~/.local/bin/localhosts links to it.
enum CLI {
    static let commands: Set<String> = ["list", "add", "stop", "help", "--help", "-h"]

    /// True when the binary was started as the command rather than as the menu bar app.
    static func wanted(_ arguments: [String]) -> Bool {
        let invokedAs = ((arguments.first ?? "") as NSString).lastPathComponent
        if invokedAs == "localhosts" { return true }
        return arguments.count > 1 && commands.contains(arguments[1])
    }

    static func run(_ arguments: [String]) -> Int32 {
        var args = Array(arguments.dropFirst())
        let command = args.isEmpty ? "list" : args.removeFirst()
        switch command {
        case "list": return list(args)
        case "add": return add(args)
        case "stop": return stop(args)
        case "help", "--help", "-h": print(usage); return 0
        default:
            printError("Unknown command '\(command)'.\n\n\(usage)")
            return 2
        }
    }

    static let usage = """
    localhosts: the servers listed in the Localhosts menu bar app

      localhosts list [--json]         every server, with the Claude session that owns it
      localhosts add <port|url> [--label TEXT] [--path /page] [--stop-cmd CMD]
                                       label a server you started (waits up to 15 s for it to listen)
      localhosts stop <port>           stop a server and the processes it started

    Servers started from Claude Code show up on their own; `add` gives them a readable
    label, a page to open, or a stop command (use one for Docker containers).
    """

    // MARK: list

    private static func list(_ args: [String]) -> Int32 {
        let (servers, _) = PortScanner().scan()
        let mySession = ProcessInfo.processInfo.environment["CLAUDE_CODE_SESSION_ID"]
        if args.contains("--json") {
            let rows: [[String: Any]] = servers.map { server in
                var row: [String: Any] = ["port": server.port, "pid": server.pid, "url": server.url.absoluteString,
                                          "label": server.label, "command": server.command, "owner": ownerText(server.owner)]
                if let cwd = server.cwd { row["cwd"] = cwd }
                if let id = server.sessionID { row["sessionID"] = id; row["mine"] = id == mySession }
                return row
            }
            let data = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])) ?? Data()
            print(String(decoding: data, as: UTF8.self))
            return 0
        }
        if servers.isEmpty { print("No servers running."); return 0 }
        print(pad("PORT", 7) + pad("OWNER", 22) + pad("LABEL", 34) + "FOLDER")
        for server in servers {
            var owner = ownerText(server.owner)
            if let id = server.sessionID, id == mySession { owner = "this session" }
            print(pad(":\(server.port)", 7) + pad(owner, 22) + pad(server.label, 34) + (server.cwd.map(tilde) ?? ""))
        }
        return 0
    }

    private static func ownerText(_ owner: Owner) -> String {
        switch owner {
        case .live(let session): return "claude " + (session.tty ?? "pid \(session.claudePID)")
        case .ended: return "claude (ended)"
        case .other: return "other"
        }
    }

    // MARK: add

    private static func add(_ args: [String]) -> Int32 {
        guard let target = args.first, !target.hasPrefix("--") else {
            printError("Say which port: localhosts add 5173 --label \"site preview\"")
            return 2
        }
        var options: [String: String] = [:]
        var index = 1
        while index < args.count {
            let key = args[index]
            guard ["--label", "--path", "--stop-cmd"].contains(key), index + 1 < args.count else {
                printError("Unknown or incomplete option '\(key)'.")
                return 2
            }
            options[key] = args[index + 1]
            index += 2
        }

        guard let (port, urlPath) = parseTarget(target) else {
            printError("'\(target)' isn't a port or a localhost URL.")
            return 2
        }

        let scanner = PortScanner()
        let deadline = Date().addingTimeInterval(15)
        var found: (Listener, ProcInfo)?
        repeat {
            let (source, listeners) = scanner.snapshot()
            if let listener = listeners.first(where: { $0.port == port }), let info = source.processes[listener.pid] {
                found = (listener, info)
            } else {
                usleep(500_000)
            }
        } while found == nil && Date() < deadline
        guard let (listener, info) = found else {
            printError("Nothing is listening on port \(port) yet. Start the server, then run this again.")
            return 1
        }

        let environment = ProcessInfo.processInfo.environment
        let entry = RegistryEntry(port: port,
                                  pid: listener.pid,
                                  pgid: info.pgid,
                                  processStart: info.startTime,
                                  label: options["--label"],
                                  path: options["--path"] ?? urlPath,
                                  stopCommand: options["--stop-cmd"],
                                  cwd: FileManager.default.currentDirectoryPath,
                                  sessionID: environment["CLAUDE_CODE_SESSION_ID"],
                                  claudePID: environment["CLAUDE_PID"].flatMap { Int32($0) },
                                  registeredAt: Date())
        do {
            try scanner.registry.save(entry)
        } catch {
            printError("Couldn't save: \(error.localizedDescription)")
            return 1
        }
        print("Listed :\(port) (\(entry.label ?? info.name)) in Localhosts.")
        return 0
    }

    static func parseTarget(_ text: String) -> (port: UInt16, path: String?)? {
        if let port = UInt16(text) { return (port, nil) }
        let withScheme = text.contains("://") ? text : "http://" + text
        guard let components = URLComponents(string: withScheme), let port = components.port,
              let host = components.host, ["localhost", "127.0.0.1", "::1", "[::1]", "0.0.0.0"].contains(host),
              let value = UInt16(exactly: port) else { return nil }
        var path = components.percentEncodedPath
        if let query = components.percentEncodedQuery { path += "?" + query }
        return (value, path.isEmpty || path == "/" ? nil : path)
    }

    // MARK: stop

    private static func stop(_ args: [String]) -> Int32 {
        guard let text = args.first, let port = UInt16(text.trimmingCharacters(in: CharacterSet(charactersIn: ":"))) else {
            printError("Say which port: localhosts stop 5173")
            return 2
        }
        let (servers, source) = PortScanner().scan()
        let matching = servers.filter { $0.port == port }
        guard !matching.isEmpty else {
            printError("Nothing in the list is listening on port \(port).")
            return 1
        }
        var status: Int32 = 0
        for server in matching {
            switch Stopper.execute(Stopper.plan(for: server, source: source)) {
            case .stopped:
                Registry.standard.remove(port: port)
                print("Stopped :\(port) (\(server.label)).")
            case .failed(let reason):
                printError("Couldn't stop :\(port): \(reason)")
                status = 1
            }
        }
        return status
    }

    // MARK: helpers

    private static func pad(_ text: String, _ width: Int) -> String {
        let clipped = text.count >= width ? String(text.prefix(width - 2)) + "…" : text
        return clipped.padding(toLength: width, withPad: " ", startingAt: 0)
    }

    private static func tilde(_ path: String) -> String {
        path.hasPrefix(NSHomeDirectory()) ? "~" + path.dropFirst(NSHomeDirectory().count) : path
    }

    private static func printError(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}
