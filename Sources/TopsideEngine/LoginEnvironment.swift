import Foundation

/// The environment a new terminal window would have.
///
/// An app started from Finder, the Dock or at login gets launchd's minimal
/// environment (PATH=/usr/bin:/bin:/usr/sbin:/sbin). Agents installed with
/// Homebrew, npm or nvm would then not be found, or would start and fail to
/// find `node`. So the app asks the user's login shell for its environment,
/// the way editors such as VS Code do, and uses that for the engine.
public enum LoginEnvironment {
    /// Variables from the app's own environment that win over the shell's:
    /// they configure Topside itself (data directory, test agents).
    static let ownPrefixes = ["TOPSIDE_", "FAKE_AGENT_"]

    /// Run `shell` as an interactive login shell (so both profile and rc files
    /// are read, which is where PATH is usually set) and read its environment.
    /// nil if the shell fails, hangs past `timeout`, or prints nothing usable.
    public static func capture(shell: String, base: [String: String], timeout: Double = 10) async -> [String: String]? {
        let marker = "__TOPSIDE_ENV_\(UUID().uuidString.prefix(8))__"
        // Markers around the output: rc files may print greetings, and those must not be parsed.
        let script = "printf '%s' '\(marker)'; /usr/bin/env -0; printf '%s' '\(marker)'"
        guard let result = try? await Command.run(shell, ["-i", "-l", "-c", script], environment: base, timeout: timeout),
              result.exitCode == 0 else { return nil }
        return parse(result.stdout, marker: marker)
    }

    static func parse(_ output: String, marker: String) -> [String: String]? {
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        var env: [String: String] = [:]
        for entry in parts[1].split(separator: "\0") {
            guard let eq = entry.firstIndex(of: "="), eq != entry.startIndex else { continue }
            env[String(entry[..<eq])] = String(entry[entry.index(after: eq)...])
        }
        return env["PATH"] == nil ? nil : env
    }

    /// The environment for an engine run by an app: the login shell's, with
    /// Topside's own settings from `process` on top. If the shell could not be
    /// asked, `process` with the usual install locations added to PATH.
    public static func resolve(process: [String: String] = ProcessInfo.processInfo.environment,
                               timeout: Double = 10) async -> [String: String] {
        let shell = process["SHELL"].flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil } ?? "/bin/zsh"
        if let captured = await capture(shell: shell, base: process, timeout: timeout) {
            return merge(shell: captured, process: process)
        }
        return withCommonPaths(process)
    }

    static func merge(shell: [String: String], process: [String: String]) -> [String: String] {
        var env = shell
        for (k, v) in process where ownPrefixes.contains(where: { k.hasPrefix($0) }) { env[k] = v }
        // Set by the shell for itself; meaningless to processes started later.
        for k in ["SHLVL", "_", "OLDPWD", "PWD"] { env[k] = nil }
        return env
    }

    static func withCommonPaths(_ process: [String: String]) -> [String: String] {
        var env = process
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let current = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin").split(separator: ":").map(String.init)
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"].filter { !current.contains($0) }
        env["PATH"] = (extra + current).joined(separator: ":")
        return env
    }
}
