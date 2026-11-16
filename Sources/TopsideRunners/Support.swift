import Foundation
import TopsideCore

enum Executables {
    /// Directories where agent CLIs are commonly installed but which a GUI
    /// app's PATH usually lacks.
    static func commonDirectories() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var dirs = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin",
                    "\(home)/.npm-global/bin", "\(home)/.volta/bin"]
        // nvm keeps one bin directory per Node version; newest first.
        let nvm = "\(home)/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvm) {
            dirs += versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
                .map { "\(nvm)/\($0)/bin" }
        }
        return dirs
    }

    static func find(_ name: String, searchPath: String?) -> String? {
        let fromPath = (searchPath ?? "").split(separator: ":").map(String.init)
        for dir in fromPath + commonDirectories() where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// First line of `<executable> --version`, or nil.
    static func version(of executable: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }
}

/// Environment variables a surrounding Claude Code session sets. They must not
/// leak into agents Topside starts, or a child agent believes it is nested
/// inside that session (M0 finding). CLAUDE_CONFIG_DIR is user configuration
/// and is kept.
let inheritedSessionVariables: Set<String> = [
    "CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID", "CLAUDE_CODE_CHILD_SESSION",
    "CLAUDE_CODE_SESSION_ATTENDED", "CLAUDE_CODE_MESSAGING_SOCKET", "CLAUDE_CODE_MESSAGING_TOKEN",
    "CLAUDE_CODE_EXECPATH", "CLAUDE_PID", "CLAUDE_EFFORT",
]

func cleanEnvironment(_ base: [String: String]) -> [String: String] {
    base.filter { !inheritedSessionVariables.contains($0.key) }
}

/// Small helpers for reading loosely typed JSON without throwing.
extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [[String: Any]]? { self[key] as? [[String: Any]] }
    func bool(_ key: String) -> Bool? { self[key] as? Bool }
    func double(_ key: String) -> Double? { (self[key] as? NSNumber)?.doubleValue }
    func int(_ key: String) -> Int? { (self[key] as? NSNumber)?.intValue }
}

func jsonObject(_ line: Data) -> [String: Any]? {
    guard !line.isEmpty else { return nil }
    return (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
}

/// One readable line for a tool call's input.
func briefDetail(_ input: [String: Any]?) -> String? {
    guard let input else { return nil }
    for key in ["command", "file_path", "path", "pattern", "url", "query", "description", "prompt"] {
        if let v = input[key] as? String, !v.isEmpty {
            let flat = v.replacingOccurrences(of: "\n", with: " ")
            return flat.count > 120 ? String(flat.prefix(119)) + "…" : flat
        }
    }
    return nil
}
