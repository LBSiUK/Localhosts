import Foundation

/// The command line and environment of a process, as the kernel hands them over in KERN_PROCARGS2.
struct ProcArgs: Equatable {
    var executable: String
    var arguments: [String]
    var environment: [String: String]

    /// Parses a raw KERN_PROCARGS2 buffer: argc as an Int32, the exec path, NUL padding,
    /// argc arguments, then environment strings up to the first empty one.
    ///
    /// Processes that rename themselves (Node's `process.title`) overwrite this area, so the
    /// arguments can come back as one string with spaces and the environment can be empty.
    static func parse(_ bytes: [UInt8]) -> ProcArgs? {
        guard bytes.count > 4 else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 0, argc < 100_000 else { return nil }
        var index = 4

        func nextString() -> String {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            let value = String(decoding: bytes[start..<index], as: UTF8.self)
            if index < bytes.count { index += 1 }
            return value
        }

        let executable = nextString()
        while index < bytes.count, bytes[index] == 0 { index += 1 }

        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            arguments.append(nextString())
        }

        var environment: [String: String] = [:]
        while index < bytes.count, bytes[index] != 0 {
            let entry = nextString()
            guard let equals = entry.firstIndex(of: "=") else { continue }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return ProcArgs(executable: executable, arguments: arguments, environment: environment)
    }
}
