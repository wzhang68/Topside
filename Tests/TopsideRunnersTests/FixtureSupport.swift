import Foundation
import TopsideCore

/// Tests/Fixtures, located from this file so `swift test` works from any directory.
enum Fixtures {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TopsideRunnersTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("Fixtures")

    static func lines(_ relativePath: String) throws -> [Data] {
        let data = try Data(contentsOf: root.appendingPathComponent(relativePath))
        return data.split(separator: UInt8(ascii: "\n")).map { Data($0) }
    }

    static func events(_ runner: some AgentRunner, _ relativePath: String) throws -> [RunEvent] {
        try lines(relativePath).flatMap { runner.parse(line: $0) }
    }

    /// Fold a fixture through the parser into a run record, as the engine does.
    static func record(_ runner: some AgentRunner, _ relativePath: String) throws -> RunRecord {
        var r = RunRecord(number: 1, directory: "/x", launchedAt: Date())
        for e in try events(runner, relativePath) { apply(e, to: &r) }
        return r
    }
}
