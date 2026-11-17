import AppKit
import TopsideUIModel

/// The menu bar icon: the fallback way in (design doc 8.7), and where the
/// global commands live (design doc 6.6, last paragraph).
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let model: IslandModel
    private weak var island: IslandController?
    private let onRetry: () -> Void

    init(model: IslandModel, island: IslandController, onRetry: @escaping () -> Void) {
        self.model = model
        self.island = island
        self.onRetry = onRetry
        super.init()
        item.button?.image = NSImage(systemSymbolName: "capsule.fill", accessibilityDescription: "Topside")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let c = model.store.counts
        let summary = [c.active > 0 ? "\(c.active) 个运行中" : nil, c.needsYou > 0 ? "\(c.needsYou) 个等你处理" : nil,
                       c.failed > 0 ? "\(c.failed) 个失败" : nil, c.ready > 0 ? "\(c.ready) 个待验收" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        menu.addItem(disabled(model.host.state == .running ? (summary.isEmpty ? "没有进行中的任务" : summary)
                                                            : model.host.statusText))
        if let unavailable = island?.unavailableHotKeys, !unavailable.isEmpty {
            menu.addItem(disabled("快捷键被占用：\(unavailable.joined(separator: "、"))"))
        }
        menu.addItem(.separator())
        menu.addItem(action("新任务", key: " ", modifiers: [.option]) { [weak self] in self?.island?.openLauncher() })
        menu.addItem(action("显示任务列表", key: " ", modifiers: [.option, .control]) { [weak self] in self?.island?.toggleList() })
        menu.addItem(.separator())
        menu.addItem(action("全部暂停") { [weak self] in self?.model.setAllPaused(true) })
        menu.addItem(action("全部继续") { [weak self] in self?.model.setAllPaused(false) })
        if model.host.state != .running && model.host.state != .starting {
            menu.addItem(action("重新启动引擎", onRetry))
        }
        menu.addItem(.separator())
        menu.addItem(action("在 Finder 中打开数据目录") { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.model.host.dataDirectory)
        })
        menu.addItem(action("退出 Topside", key: "q", modifiers: [.option]) { NSApp.terminate(nil) })
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = [],
                        _ run: @escaping () -> Void) -> NSMenuItem {
        let i = ClosureMenuItem(title: title, keyEquivalent: key, run: run)
        i.keyEquivalentModifierMask = modifiers
        return i
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, keyEquivalent: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}
