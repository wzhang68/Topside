import Foundation
import Testing
@testable import TopsideEngine

@Suite struct CommandTests {
    /// Many commands at once must not exhaust GCD's thread pool. An earlier
    /// implementation blocked one GCD thread per command while waiting for two
    /// more to drain its pipes; with dozens of commands in flight (50 tasks
    /// preparing worktrees) every thread ended up waiting and the process
    /// stalled. CI hung on it.
    @Test(.timeLimit(.minutes(1))) func manyConcurrentCommandsComplete() async throws {
        let started = Date()
        let results = try await withThrowingTaskGroup(of: Int32.self) { group in
            for i in 0..<200 {
                group.addTask {
                    try await Command.run("/bin/sh", ["-c", "sleep 0.2; echo out \(i); echo err \(i) >&2"]).exitCode
                }
            }
            return try await group.reduce(into: [Int32]()) { $0.append($1) }
        }
        #expect(results.count == 200 && results.allSatisfy { $0 == 0 })
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test func capturesBothStreamsAndTheExitCode() async throws {
        let r = try await Command.run("/bin/sh", ["-c", "printf 'a\\nb\\n'; printf 'oops' >&2; exit 3"])
        #expect(r.exitCode == 3)
        #expect(r.stdout == "a\nb\n")
        #expect(r.stderr == "oops")
        // Large output must not block (a pipe would fill up at 64 KB).
        let big = try await Command.run("/bin/sh", ["-c", "head -c 3000000 /dev/zero | tr '\\0' x"])
        #expect(big.stdout.count == 3_000_000)
    }
}
