import Foundation
import Observation
import TopsideCore
import TopsideEngine
import TopsideRunners

/// Runs the task engine inside the app, in place of `topside serve`, and
/// serves the same socket so the `topside` command line talks to the app.
///
/// Only one engine may use a data directory. If one is already running
/// (`topside serve`, or another copy of the app), the app does not start a
/// second one and says so instead.
@MainActor @Observable
final class EngineHost {
    enum State: Equatable {
        case starting
        case running
        case otherEngine
        case failed(String)
    }

    private(set) var state: State = .starting
    private(set) var engine: TaskEngine?
    /// Installed agents, in the order offered by default.
    private(set) var installedAgents: [AgentKind] = []
    /// Known before the engine starts: TOPSIDE_HOME comes from the app's own environment.
    let dataDirectory = EngineConfiguration.standard().dataDirectory
    @ObservationIgnored let runners: [any AgentRunner]
    @ObservationIgnored private var server: ControlServer?

    init() {
        // TOPSIDE_FAKE_AGENT: every agent is scripts/fake-agent.sh (interface work without a model).
        let fake = ProcessInfo.processInfo.environment["TOPSIDE_FAKE_AGENT"]
        runners = [ClaudeCodeRunner(executableOverride: fake), CodexRunner(executableOverride: fake)]
    }

    func displayName(_ kind: AgentKind) -> String {
        runners.first { $0.kind == kind }?.displayName ?? kind.rawValue
    }

    func runner(_ kind: AgentKind) -> (any AgentRunner)? {
        runners.first { $0.kind == kind }
    }

    var statusText: String {
        switch state {
        case .starting: return "引擎正在启动…"
        case .running: return "引擎运行中"
        case .otherEngine: return "另一个引擎正在运行（可能是 topside serve）。停掉它后重试。"
        case .failed(let message): return "引擎没有启动：\(message)"
        }
    }

    /// Start the engine. nil if it could not be started (see `state`).
    func start() async -> TaskEngine? {
        if let engine { return engine }
        state = .starting
        let environment = await LoginEnvironment.resolve()
        let configuration = EngineConfiguration.standard(environment: environment)
        if ControlClient.isEngineRunning(socketPath: configuration.socketPath) {
            state = .otherEngine
            return nil
        }
        do {
            let engine = try TaskEngine(configuration: configuration, runners: runners)
            try configuration.prepareSocketLocation()
            let server = ControlServer(engine: engine, path: configuration.socketPath)
            try server.start()
            await engine.start()
            var agents: [AgentKind] = []
            for r in runners where await engine.installation(for: r.kind) != nil { agents.append(r.kind) }
            self.engine = engine
            self.server = server
            installedAgents = agents
            state = .running
            return engine
        } catch {
            state = .failed("\(error)")
            return nil
        }
    }

    /// Stop serving and let go of the agents without stopping them.
    func shutdown() async {
        server?.stop()
        server = nil
        await engine?.detach()
    }
}
