import Foundation
import Testing
@testable import TopsideIPC

/// Socket paths must stay under 104 bytes, so tests use /tmp rather than the long temp dir.
private func socketPath() -> String { "/tmp/topside-test-\(UUID().uuidString.prefix(8)).sock" }

@Suite struct LineSocketTests {
    @Test func roundTripAndConcurrentClients() async throws {
        let path = socketPath()
        let server = LineSocketServer(path: path) { request in
            Data("echo:".utf8) + request
        }
        try server.start()
        defer { server.stop() }

        let reply = try await LineSocketClient.send(path: path, Data("hello".utf8))
        #expect(String(decoding: reply, as: UTF8.self) == "echo:hello")

        let replies = try await withThrowingTaskGroup(of: String.self) { group in
            for i in 0..<40 {
                group.addTask {
                    let r = try await LineSocketClient.send(path: path, Data("m\(i)".utf8))
                    return String(decoding: r, as: UTF8.self)
                }
            }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(replies == Set((0..<40).map { "echo:m\($0)" }))
    }

    @Test func socketFileIsPrivate() throws {
        let path = socketPath()
        let server = LineSocketServer(path: path) { $0 }
        try server.start()
        defer { server.stop() }
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func secondServerRefusesAndStaleSocketIsReplaced() throws {
        let path = socketPath()
        let first = LineSocketServer(path: path) { $0 }
        try first.start()
        do {
            let second = LineSocketServer(path: path) { $0 }
            #expect(throws: SocketError.alreadyRunning(path)) { try second.start() }
            second.stop()
        }   // and deinit
        // The refused server must not have removed the running server's socket.
        #expect(LineSocketClient.isListening(path))
        first.stop()

        // A leftover socket file with nobody listening must not block a new server.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try makeAddress(path)
        _ = withSockaddr(&addr) { bind(fd, $0, $1) }
        close(fd)
        #expect(FileManager.default.fileExists(atPath: path))
        let second = LineSocketServer(path: path) { $0 }
        try second.start()
        second.stop()
    }

    @Test func clientErrors() {
        #expect(throws: SocketError.self) { try LineSocketClient.request(path: socketPath(), Data("x".utf8), timeout: 1) }
        let long = "/tmp/" + String(repeating: "a", count: 120)
        #expect(throws: SocketError.pathTooLong(long)) { try LineSocketClient.request(path: long, Data()) }
        #expect(!LineSocketClient.isListening(socketPath()))
    }
}
