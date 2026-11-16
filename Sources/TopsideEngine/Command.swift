import Foundation

public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    /// The last `lines` lines of stderr+stdout, for failure messages.
    public func tail(_ lines: Int = 20) -> String {
        let all = (stdout + (stderr.isEmpty ? "" : "\n" + stderr))
            .split(whereSeparator: \.isNewline)
        return all.suffix(lines).joined(separator: "\n")
    }
}

final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// Short-lived commands (git, prep commands). Agent processes do not go
/// through here; they are detached by `ProcessSupervisor`.
enum Command {
    static func run(_ executable: String, _ arguments: [String], in directory: String? = nil,
                    environment: [String: String]? = nil) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                if let directory { p.currentDirectoryURL = URL(fileURLWithPath: directory) }
                if let environment { p.environment = environment }
                p.standardInput = FileHandle.nullDevice
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do {
                    try p.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let o = Box(Data()), e = Box(Data())
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async { o.value = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter()
                DispatchQueue.global().async { e.value = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.wait()
                p.waitUntilExit()
                continuation.resume(returning: CommandResult(
                    exitCode: p.terminationStatus,
                    stdout: String(decoding: o.value, as: UTF8.self),
                    stderr: String(decoding: e.value, as: UTF8.self)))
            }
        }
    }

    /// A user-supplied command line (prep or verify), run by the login shell
    /// so PATH matches what the user sees in a terminal.
    static func shell(_ commandLine: String, in directory: String,
                      environment: [String: String]) async throws -> CommandResult {
        try await run("/bin/zsh", ["-lc", commandLine], in: directory, environment: environment)
    }
}
