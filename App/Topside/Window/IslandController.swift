import AppKit
import Carbon.HIToolbox
import SwiftUI
import TopsideUIModel

/// A borderless, non-activating panel above the menu bar, on every Space and
/// over full-screen apps (design doc 8.7, M0 conclusion 4).
final class IslandPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }   // the launcher's text field needs keys
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

/// Buttons react to the first click even though the panel never activates the app.
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The island's window: placement, hover, clicks, hot keys and keyboard focus.
@MainActor
final class IslandController: IslandWindow {
    static let hoverOpenDelay: Duration = .milliseconds(150)
    static let hoverCloseDelay: Duration = .milliseconds(300)

    let model: IslandModel
    private var panel: IslandPanel!
    private let hotKeys = HotKeys()
    /// Opened by a click or hot key: stays open until dismissed, not just until the mouse leaves.
    private var pinned = false
    private var hoverTask: Task<Void, Never>?
    private var previousApp: NSRunningApplication?
    private var monitors: [Any] = []
    private var keyMonitor: Any?
    private var menuOpen = false

    init(model: IslandModel) {
        self.model = model
        model.window = self
    }

    func start() {
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.ignoresMouseEvents = true
        panel.onCancel = { [weak self] in self?.escape() }
        panel.contentView = IslandHostingView(rootView: IslandRootView(model: model))

        reposition()
        panel.orderFrontRegardless()

        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        // A ⋯ menu is a separate window: the mouse leaving the island for it must not close the island.
        center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuOpen = true }
        }
        center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuOpen = false
                self?.mouseMoved()
            }
        }

        let moved: (NSEvent) -> Void = { [weak self] _ in MainActor.assumeIsolated { self?.mouseMoved() } }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: moved) {
            monitors.append(m)
        }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }) {
            monitors.append(m)
        }
        // Clicks elsewhere (they reach other apps, so only a global monitor sees them).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside() }
        }) {
            monitors.append(m)
        }

        hotKeys.register(id: 1, keyCode: kVK_Space, modifiers: optionKey, name: "⌥Space") { [weak self] in
            self?.toggleLauncher()
        }
        hotKeys.register(id: 2, keyCode: kVK_Space, modifiers: optionKey | controlKey, name: "⌃⌥Space") { [weak self] in
            self?.toggleList()
        }
        if !hotKeys.unavailable.isEmpty {
            model.show("快捷键被其他应用占用：\(hotKeys.unavailable.joined(separator: "、"))")
        }
        // For screenshots and interface work (scripts/demo-island.sh): open in a given shape.
        switch ProcessInfo.processInfo.environment["TOPSIDE_ISLAND_START"] {
        case "expanded": expand(pinned: true)
        case "launcher": openLauncher()
        default: break
        }
    }

    var unavailableHotKeys: [String] { hotKeys.unavailable }

    // MARK: Placement

    /// The island lives on the primary screen (the one with the menu bar).
    private func reposition() {
        guard let screen = NSScreen.screens.first else { return }
        let g = NotchGeometry(ScreenMetrics(
            frame: screen.frame, visibleFrame: screen.visibleFrame, safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea, auxiliaryTopRight: screen.auxiliaryTopRightArea))
        model.geometry = g
        panel.setFrame(g.canvasFrame, display: true)
    }

    private func isOverIsland(_ p: CGPoint = NSEvent.mouseLocation, size: CGSize? = nil) -> Bool {
        model.geometry.contains(p, islandSize: size ?? model.islandSize)
    }

    // MARK: Hover and clicks

    private func mouseMoved() {
        let inside = isOverIsland()
        // Only the island takes the mouse; the transparent rest of the canvas lets clicks through.
        panel.ignoresMouseEvents = !inside
        guard !menuOpen else { return }
        switch model.mode {
        case .collapsed where inside:
            hover(after: Self.hoverOpenDelay) { [weak self] in
                guard let self, self.isOverIsland(), self.model.mode == .collapsed else { return }
                self.expand(pinned: false)
            }
        case .expanded where !inside && !pinned:
            hover(after: Self.hoverCloseDelay) { [weak self] in
                guard let self, !self.isOverIsland(), self.model.mode == .expanded, !self.pinned, !self.menuOpen else { return }
                self.collapse()
            }
        case .collapsed, .expanded:
            hoverTask?.cancel()
        case .launcher:
            break
        }
    }

    private func hover(after delay: Duration, _ work: @escaping @MainActor () -> Void) {
        hoverTask?.cancel()
        hoverTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { work() }
        }
    }

    private func clickedOutside() {
        guard !menuOpen, !isOverIsland() else { return }
        switch model.mode {
        case .expanded: collapse()
        case .launcher: closeLauncher(clear: false)
        case .collapsed: break
        }
    }

    // MARK: Modes

    func expand(pinned: Bool) {
        self.pinned = pinned
        model.mode = .expanded
    }

    func collapse() {
        hoverTask?.cancel()
        let hadKeys = panel.isKeyWindow
        pinned = false
        model.mode = .collapsed
        model.confirmingDiscard = nil
        releaseKeys(returnFocus: hadKeys)
        panel.ignoresMouseEvents = !isOverIsland(size: model.collapsedSize)
    }

    func toggleLauncher() {
        if model.mode == .launcher { closeLauncher(clear: false) } else { openLauncher() }
    }

    /// ⌃⌥Space: the list, with the keyboard, until Esc or the hot key again.
    func toggleList() {
        if model.mode == .expanded && pinned {
            collapse()
            return
        }
        if model.mode == .launcher { closeLauncher(clear: false) }
        rememberFrontApp()
        expand(pinned: true)
        takeKeys()
    }

    func openLauncher() {
        if model.mode != .launcher { rememberFrontApp() }
        model.prepareDraft()
        model.mode = .launcher
        pinned = true
        takeKeys()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))   // after the field exists
            model.focusRequest += 1
        }
    }

    func closeLauncher(clear: Bool) {
        guard model.mode == .launcher else { return }
        if clear { model.draft.text = "" }
        model.launcherMessage = nil
        collapse()
    }

    private func escape() {
        switch model.mode {
        case .launcher: closeLauncher(clear: true)
        case .expanded: collapse()
        case .collapsed: break
        }
    }

    // MARK: Keyboard focus

    private func rememberFrontApp() {
        let front = NSWorkspace.shared.frontmostApplication
        if front != NSRunningApplication.current { previousApp = front }
    }

    /// The panel takes the keyboard without activating Topside, so the app
    /// you were in stays active and gets its focus back afterwards.
    private func takeKeys() {
        panel.makeKeyAndOrderFront(nil)
        if keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Decide on the main actor; NSEvent itself cannot cross into the closure's result.
                let keyCode = Int(event.keyCode)
                let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let swallow = MainActor.assumeIsolated { self?.handleKey(keyCode, mods) ?? false }
                return swallow ? nil : event
            }
        }
    }

    /// `returnFocus`: reactivate the app you were in. Not when you clicked
    /// into another app to close the island: that app already has the focus.
    private func releaseKeys(returnFocus: Bool) {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        if panel.isKeyWindow { panel.resignKey() }
        if returnFocus, let app = previousApp, !app.isTerminated { app.activate() }
        previousApp = nil
    }

    /// Handles keys the text field must not get. true swallows the key.
    private func handleKey(_ keyCode: Int, _ mods: NSEvent.ModifierFlags) -> Bool {
        // While an input method is composing (e.g. pinyin), Return, Esc, Tab and
        // the arrows belong to it.
        if let editor = panel.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
        if keyCode == kVK_Escape {
            escape()
            return true
        }
        guard model.mode == .launcher else { return false }
        let hasSuggestions = !model.suggestions.isEmpty
        switch keyCode {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mods.contains(.shift) {
                (panel.firstResponder as? NSTextView)?.insertNewlineIgnoringFieldEditor(nil)
            } else {
                model.submit(keepOpen: mods.contains(.command))
            }
            return true
        case kVK_Tab:
            if hasSuggestions { model.acceptSuggestion() } else { model.draft.moveFocus(forward: !mods.contains(.shift)) }
            return true
        case kVK_UpArrow, kVK_DownArrow:
            guard hasSuggestions else { return false }
            model.draft.moveSuggestion(by: keyCode == kVK_UpArrow ? -1 : 1, count: model.suggestions.count)
            return true
        case kVK_LeftArrow, kVK_RightArrow:
            guard model.draft.focus != .prompt else { return false }
            model.draft.cycle(forward: keyCode == kVK_RightArrow, repos: model.knownRepos,
                              agents: model.agents, recipes: [.quick])
            return true
        default:
            return false
        }
    }
}
