import AppKit
import TopsideEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let host = EngineHost()
    let store = IslandStore()
    private var model: IslandModel!
    private var island: IslandController!
    private var statusMenu: StatusMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = IslandModel(host: host, store: store)
        island = IslandController(model: model)
        island.start()
        statusMenu = StatusMenu(model: model, island: island, onRetry: { [weak self] in self?.bootEngine() })
        bootEngine()
    }

    /// The island is up before the engine: reading the login shell's
    /// environment can take a couple of seconds.
    private func bootEngine() {
        Task {
            guard let engine = await host.start() else { return }
            await store.attach(engine)
            model.engineStarted()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Agents keep running; the next launch re-attaches to them.
        Task {
            await host.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
