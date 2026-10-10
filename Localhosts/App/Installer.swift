import Foundation

/// Puts the `localhosts` command and the Claude Code skill in place each time the installed app
/// opens, so a copy dragged in from the DMG works with agents straight away.
enum Installer {
    static let commandPath = NSHomeDirectory() + "/.local/bin/localhosts"
    static let skillPath = NSHomeDirectory() + "/.claude/skills/localhosts/SKILL.md"

    static func run() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        linkCommand()
        installSkill()
    }

    /// Links ~/.local/bin/localhosts to this app, unless something else already uses that name.
    private static func linkCommand() {
        guard let executable = Bundle.main.executablePath else { return }
        let files = FileManager.default
        if let existing = try? files.destinationOfSymbolicLink(atPath: commandPath) {
            guard existing != executable, existing.hasSuffix("Localhosts.app/Contents/MacOS/Localhosts") else { return }
            try? files.removeItem(atPath: commandPath)
        } else if files.fileExists(atPath: commandPath) {
            return
        }
        try? files.createDirectory(atPath: (commandPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? files.createSymbolicLink(atPath: commandPath, withDestinationPath: executable)
    }

    /// Copies the bundled skill into ~/.claude/skills when Claude Code is set up, and keeps it current.
    private static func installSkill() {
        let files = FileManager.default
        guard files.fileExists(atPath: NSHomeDirectory() + "/.claude"),
              let bundled = Bundle.main.url(forResource: "SKILL", withExtension: "md"),
              let contents = try? Data(contentsOf: bundled),
              files.contents(atPath: skillPath) != contents else { return }
        try? files.createDirectory(atPath: (skillPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? contents.write(to: URL(fileURLWithPath: skillPath), options: .atomic)
    }
}
