import Foundation
import TopsideCore
import TopsideIPC

/// The CLI ↔ engine protocol: one JSON request, one JSON response per connection.
/// Read-only commands (list, show, logs) read the data directory directly and
/// do not need the engine; everything that changes a task goes through here.
public struct ControlRequest: Codable, Sendable, Equatable {
    public enum Action: String, Codable, Sendable {
        case ping, submit, stop, discard, pause, resume, pauseAll, resumeAll
    }

    public var action: Action
    public var taskID: TaskID?
    public var submit: TaskRequest?

    public init(action: Action, taskID: TaskID? = nil, submit: TaskRequest? = nil) {
        self.action = action
        self.taskID = taskID
        self.submit = submit
    }
}

public struct ControlResponse: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var task: TopsideTask?

    public static func success(_ task: TopsideTask? = nil) -> ControlResponse { ControlResponse(ok: true, task: task) }
    public static func failure(_ message: String) -> ControlResponse { ControlResponse(ok: false, error: message) }
}

public final class ControlServer: Sendable {
    let socket: LineSocketServer

    public init(engine: TaskEngine, path: String) {
        socket = LineSocketServer(path: path) { data in
            let response: ControlResponse
            if let request = try? JSONDecoder().decode(ControlRequest.self, from: data) {
                response = await ControlServer.handle(request, engine: engine)
            } else {
                response = .failure("Malformed request.")
            }
            return (try? JSONEncoder().encode(response)) ?? Data(#"{"ok":false}"#.utf8)
        }
    }

    public func start() throws { try socket.start() }
    public func stop() { socket.stop() }

    static func handle(_ request: ControlRequest, engine: TaskEngine) async -> ControlResponse {
        do {
            switch request.action {
            case .ping:
                return .success()
            case .submit:
                guard let submit = request.submit else { return .failure("Missing task.") }
                return .success(try await engine.submit(submit))
            case .pauseAll, .resumeAll:
                await engine.setAllPaused(request.action == .pauseAll)
                return .success()
            case .stop, .discard, .pause, .resume:
                guard let id = request.taskID else { return .failure("Missing task id.") }
                switch request.action {
                case .stop: try await engine.stop(id)
                case .discard: try await engine.discard(id)
                case .pause: try await engine.setPaused(id, true)
                default: try await engine.setPaused(id, false)
                }
                return .success(await engine.task(id))
            }
        } catch {
            return .failure("\(error)")
        }
    }
}

public enum ControlClient {
    public static func send(_ request: ControlRequest, socketPath: String, timeout: TimeInterval = 60) async throws -> ControlResponse {
        let reply = try await LineSocketClient.send(path: socketPath, try JSONEncoder().encode(request), timeout: timeout)
        return try JSONDecoder().decode(ControlResponse.self, from: reply)
    }

    public static func isEngineRunning(socketPath: String) -> Bool {
        LineSocketClient.isListening(socketPath)
    }
}
