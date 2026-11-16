import Foundation
import Testing
@testable import TopsideUIModel

private actor Batches {
    var all: [[String: Int]] = []
    func add(_ b: [String: Int]) { all.append(b) }
}

@Suite struct UpdateBatcherTests {
    @Test(.timeLimit(.minutes(1)))
    func burstsAreMergedKeepingTheLatestValue() async throws {
        let (stream, input) = AsyncStream.makeStream(of: (String, Int).self)
        let batches = Batches()
        let batcher = UpdateBatcher<String, (String, Int)>()
        let done = AsyncStream.makeStream(of: Void.self)
        batcher.start(stream, key: { $0.0 }, interval: .milliseconds(200)) { batch in
            await batches.add(batch.mapValues(\.1))
            done.continuation.yield()
        }
        // The first update goes out on its own and at once...
        input.yield(("a", 0))
        var it = done.stream.makeAsyncIterator()
        await it.next()
        // ...then a burst during the pause arrives as one batch, latest values only.
        for i in 1...500 { input.yield((i % 2 == 0 ? "a" : "b", i)) }
        input.finish()
        var latest: [String: Int] = [:]
        while latest != ["a": 500, "b": 499] {
            await it.next()
            latest.merge(await batches.all.last!) { $1 }
        }
        let all = await batches.all
        #expect(all.first == ["a": 0])
        // Normally exactly one more batch; a slow machine may split the burst once more.
        #expect(all.count <= 3)
    }
}
