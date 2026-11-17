import Foundation

public struct GitError: Error, CustomStringConvertible {
    public var message: String
    public var detail: String?
    public var description: String { detail.map { "\(message)\n\($0)" } ?? message }
}

/// A git executable known to be new enough (design doc 8.2: never trust PATH
/// blindly; M0 found git 2.16 first on PATH, which lacks `worktree remove`).
public struct Git: Sendable {
    public static let minimumVersion = [2, 25]

    public let executable: String
    public let version: String
    let environment: [String: String]

    /// `git worktree add --orphan`, for repositories with no commits yet (git 2.42).
    var supportsOrphanWorktrees: Bool {
        !version.split(separator: ".").compactMap { Int($0) }.lexicographicallyPrecedes([2, 42])
    }

    public static func locate(searchPath: String? = ProcessInfo.processInfo.environment["PATH"],
                              environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Git {
        var candidates = ["/usr/bin/git", "/opt/homebrew/bin/git"]
        candidates += (searchPath ?? "").split(separator: ":").map { "\($0)/git" }
        var tried: [String] = []
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) && !tried.contains(path) {
            tried.append(path)
            guard let v = versionNumbers(path), v.lexicographicallyPrecedes(minimumVersion) == false else { continue }
            var env = environment
            env["GIT_TERMINAL_PROMPT"] = "0"   // never block on a credential prompt
            env["GIT_OPTIONAL_LOCKS"] = "0"
            return Git(executable: path, version: v.map(String.init).joined(separator: "."), environment: env)
        }
        throw GitError(message: "No git \(minimumVersion.map(String.init).joined(separator: ".")) or newer found.",
                       detail: "Tried: \(tried.joined(separator: ", "))")
    }

    static func versionNumbers(_ path: String) -> [Int]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard let match = text.firstMatch(of: /(\d+)\.(\d+)(?:\.(\d+))?/) else { return nil }
        return [Int(match.1)!, Int(match.2)!, match.3.flatMap { Int($0) } ?? 0]
    }

    /// Run git in `directory`; throw with stderr on a non-zero exit.
    @discardableResult
    func run(_ arguments: [String], in directory: String, extraEnvironment: [String: String] = [:]) async throws -> String {
        let r = try await Command.run(executable, arguments, in: directory,
                                      environment: environment.merging(extraEnvironment) { $1 })
        guard r.exitCode == 0 else {
            throw GitError(message: "git \(arguments.first ?? "") failed (exit \(r.exitCode)).",
                           detail: r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r.stdout
    }

    func trimmed(_ arguments: [String], in directory: String) async throws -> String {
        try await run(arguments, in: directory).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
