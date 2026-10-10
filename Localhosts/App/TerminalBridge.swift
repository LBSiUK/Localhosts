import Foundation

/// Talks to Terminal.app over Apple Events: brings up the tab for a tty, or opens a new one.
enum TerminalBridge {
    enum Outcome: Equatable {
        case done
        case tabNotFound
        case notAuthorised
        case failed(String)
    }

    static func focus(tty: String) -> Outcome {
        let device = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "\(escape(device))" then
                        if miniaturized of w then set miniaturized of w to false
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "missing"
        """
        switch run(script) {
        case .success(let result): return result == "ok" ? .done : .tabNotFound
        case .failure(let outcome): return outcome
        }
    }

    /// Opens a new Terminal window running `command` in `folder`.
    static func run(command: String, in folder: String?) -> Outcome {
        var line = command
        if let folder { line = "cd \(shellQuote(folder)) && " + command }
        let script = """
        tell application "Terminal"
            activate
            do script "\(escape(line))"
        end tell
        return "ok"
        """
        switch run(script) {
        case .success: return .done
        case .failure(let outcome): return outcome
        }
    }

    private static func run(_ source: String) -> Result<String, OutcomeError> {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .failure(.failed("Couldn't build the script.")) }
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            if number == -1743 || number == -10004 { return .failure(.notAuthorised) }
            return .failure(.failed(error[NSAppleScript.errorMessage] as? String ?? "Terminal didn't respond (\(number))."))
        }
        return .success(result.stringValue ?? "")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static let automationSettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}

typealias OutcomeError = TerminalBridge.Outcome
extension TerminalBridge.Outcome: Error {}
