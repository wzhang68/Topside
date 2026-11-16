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

/// Short-lived commands (git, prep commands). Agent processes do not go
/// through here; they are detached by `ProcessSupervisor`.
///
/// No thread waits for anything: output goes to temporary files (not pipes,
/// which need a reader to keep the child from blocking once 64 KB are
/// buffered), and completion arrives through the termination handler. An
/// earlier version parked one GCD thread per command while two more drained
/// its pipes; with dozens of commands in flight GCD ran out of threads and
/// the whole process stalled (the CI hang during M1).
enum Command {
    /// `timeout`: seconds after which the command is terminated (SIGTERM, then SIGKILL 2 s later).
    static func run(_ executable: String, _ arguments: [String], in directory: String? = nil,
                    environment: [String: String]? = nil, timeout: Double? = nil) async throws -> CommandResult {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("topside-cmd-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out")
        let errURL = base.appendingPathExtension("err")
        fm.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        fm.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        defer {
            try? fm.removeItem(at: outURL)
            try? fm.removeItem(at: errURL)
        }
        let out = try FileHandle(forWritingTo: outURL)
        let err = try FileHandle(forWritingTo: errURL)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        if let directory { p.currentDirectoryURL = URL(fileURLWithPath: directory) }
        if let environment { p.environment = environment }
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = out
        p.standardError = err

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            p.terminationHandler = { process in continuation.resume(returning: process.terminationStatus) }
            do {
                try p.run()
                if let timeout {
                    let pid = p.processIdentifier
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        guard p.isRunning else { return }
                        kill(pid, SIGTERM)
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(pid, SIGKILL) } }
                    }
                }
            } catch {
                p.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        try? out.close()
        try? err.close()
        return CommandResult(exitCode: status,
                             stdout: (try? String(contentsOf: outURL, encoding: .utf8)) ?? "",
                             stderr: (try? String(contentsOf: errURL, encoding: .utf8)) ?? "")
    }

    /// A user-supplied command line (prep or verify), run by the login shell
    /// so PATH matches what the user sees in a terminal.
    static func shell(_ commandLine: String, in directory: String,
                      environment: [String: String]) async throws -> CommandResult {
        try await run("/bin/zsh", ["-lc", commandLine], in: directory, environment: environment)
    }
}
