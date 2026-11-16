// M0 spike: island window prototype. Throwaway code, not part of the product.
//
// Checks, by hand, on each display setup:
//   1. The island sits at the top centre of the primary screen, over the menu bar.
//   2. On a notched screen it wraps the notch; elsewhere it is a black pill.
//   3. It stays visible on every Space and over full-screen apps.
//   4. Hovering expands it (150 ms), leaving collapses it (300 ms); clicks on
//      the transparent area around it reach the app underneath.
//   5. ⌥Space opens a text field you can type into without the app you were
//      in losing its place; Esc or Return closes it and focus goes back.
//   6. Plugging / unplugging a display moves it to the right place.
//
// Run:  swift run --package-path Spikes/m0-window
// Quit: hover to expand, click "退出", or Ctrl-C in the terminal.

import AppKit
import Carbon.HIToolbox
import Observation
import SwiftUI

// MARK: - Model

@Observable
final class IslandModel {
    enum Mode { case collapsed, expanded, launcher }

    var mode: Mode = .collapsed
    var text = ""
    var focusRequest = 0
    var notchWidth: CGFloat = 0          // 0 means the screen has no notch
    var topBarHeight: CGFloat = 24       // notch height, or menu bar height
    var screenInfo = ""
    var log: [String] = []

    var pillSize: CGSize {
        switch mode {
        case .collapsed:
            let ears: CGFloat = 70
            return CGSize(width: (notchWidth > 0 ? notchWidth : 80) + ears * 2, height: topBarHeight)
        case .expanded:
            return CGSize(width: 460, height: 230)
        case .launcher:
            return CGSize(width: 580, height: topBarHeight + 62)
        }
    }

    func note(_ s: String) {
        let line = "\(Date().formatted(date: .omitted, time: .standard))  \(s)"
        print(line)
        log.append(line)
        if log.count > 5 { log.removeFirst(log.count - 5) }
    }
}

// MARK: - Views

struct IslandView: View {
    @Bindable var model: IslandModel
    var onTap: () -> Void
    var onSubmit: () -> Void
    var onCancel: () -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(width: model.pillSize.width, height: model.pillSize.height, alignment: .top)
                .background(
                    UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
                        .fill(Color.black)
                )
                .contentShape(Rectangle())
                .onTapGesture { if model.mode == .collapsed { onTap() } }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.32, dampingFraction: 0.82), value: model.mode)
        .onChange(of: model.focusRequest) { fieldFocused = true }
    }

    private var radius: CGFloat { model.mode == .collapsed ? 10 : 22 }

    @ViewBuilder private var content: some View {
        switch model.mode {
        case .collapsed:
            HStack(spacing: 0) {
                Label("2", systemImage: "circle.lefthalf.filled").padding(.leading, 14)
                Spacer(minLength: model.notchWidth > 0 ? model.notchWidth : 8)
                HStack(spacing: 8) {
                    Label("1", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Label("1", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }.padding(.trailing, 14)
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxHeight: .infinity)

        case .expanded:
            VStack(alignment: .leading, spacing: 8) {
                Spacer().frame(height: model.topBarHeight)
                row("exclamationmark.circle.fill", .orange, "重构配置加载", "想执行 rm -rf build/")
                row("circle.lefthalf.filled", .white, "加限流中间件", "计划 ✓  实现 ◐  验证 ○")
                row("checkmark.circle.fill", .green, "修复登录 bug", "3 个文件 +42 −7 · 测试通过")
                Divider().overlay(Color.white.opacity(0.2))
                Text(model.screenInfo).font(.system(size: 10)).foregroundStyle(.gray)
                HStack {
                    Text("⌥Space 派活").font(.system(size: 10)).foregroundStyle(.gray)
                    Spacer()
                    Button("退出") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.gray)
                        .font(.system(size: 10))
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

        case .launcher:
            VStack(alignment: .leading, spacing: 6) {
                Spacer().frame(height: model.topBarHeight)
                TextField("描述一个任务，回车派出…", text: $model.text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16))
                    .foregroundStyle(.white)
                    .focused($fieldFocused)
                    .onSubmit(onSubmit)
                    .onExitCommand(perform: onCancel)
                Text("@仓库   Claude   /实现并验证   隔离          ↩ 派出   Esc 取消")
                    .font(.system(size: 11)).foregroundStyle(.gray)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
        }
    }

    private func row(_ icon: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(color)
            Text(title).foregroundStyle(.white).font(.system(size: 13, weight: .medium))
            Spacer()
            Text(detail).foregroundStyle(.gray).font(.system(size: 12))
        }
    }
}

// MARK: - Panel

final class IslandPanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }      // needed for the launcher's text field
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

// MARK: - Controller

final class IslandController {
    let model = IslandModel()
    private var panel: IslandPanel!
    private let canvas = CGSize(width: 660, height: 300)   // window never resizes; content animates inside
    private var screenFrame: CGRect = .zero
    private var pendingHover: DispatchWorkItem?
    private var previousApp: NSRunningApplication?
    private var hotKeyRef: EventHotKeyRef?
    private var monitors: [Any] = []

    func start() {
        panel = IslandPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        // SPIKE_LEVEL lets M0 compare window levels without rebuilding.
        if let raw = ProcessInfo.processInfo.environment["SPIKE_LEVEL"], let n = Int(raw) {
            panel.level = NSWindow.Level(rawValue: n)
        } else {
            panel.level = .statusBar
        }
        if ProcessInfo.processInfo.environment["SPIKE_START"] == "expanded" { model.mode = .expanded }
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.onCancel = { [weak self] in self?.closeLauncher(submitted: false) }
        panel.contentView = NSHostingView(rootView: IslandView(
            model: model,
            onTap: { [weak self] in self?.model.mode = .expanded },
            onSubmit: { [weak self] in self?.closeLauncher(submitted: true) },
            onCancel: { [weak self] in self?.closeLauncher(submitted: false) }))

        reposition()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.model.note("屏幕配置变化，重新定位")
            self?.reposition()
        }
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.mouseMoved() }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .mouseExited], handler: { [weak self] e in
            self?.mouseMoved(); return e
        }) {
            monitors.append(l)
        }
        registerHotKey()
        model.note("已启动 · \(model.screenInfo)")
    }

    // Primary screen = the one with the menu bar.
    private func reposition() {
        guard let screen = NSScreen.screens.first else { return }
        let f = screen.frame
        screenFrame = f
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notchWidth = f.width - left.width - right.width
            model.topBarHeight = screen.safeAreaInsets.top
        } else {
            model.notchWidth = 0
            let menuBar = f.maxY - screen.visibleFrame.maxY
            model.topBarHeight = menuBar > 0 ? menuBar : 24     // 0 when the menu bar auto-hides
        }
        model.screenInfo = "\(screen.localizedName) · \(Int(f.width))×\(Int(f.height))pt · 刘海："
            + (model.notchWidth > 0 ? "有，宽 \(Int(model.notchWidth))pt" : "无")
            + " · 顶栏高 \(Int(model.topBarHeight))pt"
        panel.setFrame(CGRect(x: f.midX - canvas.width / 2, y: f.maxY - canvas.height,
                              width: canvas.width, height: canvas.height), display: true)
    }

    private func pillRect(for mode: IslandModel.Mode) -> CGRect {
        let saved = model.mode
        model.mode = mode
        let s = model.pillSize
        model.mode = saved
        return CGRect(x: screenFrame.midX - s.width / 2, y: screenFrame.maxY - s.height,
                      width: s.width, height: s.height).insetBy(dx: -4, dy: -4)
    }

    // Only the black pill takes clicks; the transparent rest of the canvas lets them through.
    private func mouseMoved() {
        let p = NSEvent.mouseLocation
        let inside = pillRect(for: model.mode).contains(p)
        if model.mode != .launcher { panel.ignoresMouseEvents = !inside }

        switch model.mode {
        case .collapsed where inside:
            schedule(after: 0.15) { [weak self] in
                guard let self, self.pillRect(for: .collapsed).contains(NSEvent.mouseLocation) else { return }
                self.model.mode = .expanded
            }
        case .expanded where !inside:
            schedule(after: 0.30) { [weak self] in
                guard let self, !self.pillRect(for: .expanded).contains(NSEvent.mouseLocation),
                      self.model.mode == .expanded else { return }
                self.model.mode = .collapsed
                self.panel.ignoresMouseEvents = true
            }
        case .collapsed, .expanded:
            pendingHover?.cancel()
        case .launcher:
            break
        }
    }

    private func schedule(after seconds: Double, _ work: @escaping () -> Void) {
        pendingHover?.cancel()
        let item = DispatchWorkItem(block: work)
        pendingHover = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    // MARK: Launcher and focus

    func toggleLauncher() {
        if model.mode == .launcher { closeLauncher(submitted: false) } else { openLauncher() }
    }

    private func openLauncher() {
        previousApp = NSWorkspace.shared.frontmostApplication
        model.mode = .launcher
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)          // non-activating: the panel takes keys, our app does not activate
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.model.focusRequest += 1 }
        model.note("输入框打开 · 当前前台应用：\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
    }

    private func closeLauncher(submitted: Bool) {
        guard model.mode == .launcher else { return }
        if submitted, !model.text.isEmpty { model.note("派出：\(model.text)") }
        model.text = ""
        model.mode = .collapsed
        panel.ignoresMouseEvents = true
        panel.resignKey()
        if let prev = previousApp, prev != NSRunningApplication.current { prev.activate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.model.note("输入框关闭 · 焦点回到：\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
        }
    }

    // MARK: Global hot key (⌥Space) via Carbon; needs no Accessibility permission.

    private func registerHotKey() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let me = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let controller = Unmanaged<IslandController>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { controller.toggleLauncher() }
            return noErr
        }, 1, &spec, me, nil)
        let id = EventHotKeyID(signature: OSType(0x5450_5344), id: 1)   // 'TPSD'
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        model.note(status == noErr ? "⌥Space 已注册" : "⌥Space 注册失败（\(status)），可能被其他应用占用")
    }
}

// MARK: - Entry point

setvbuf(stdout, nil, _IONBF, 0)          // logs reach a pipe immediately

let app = NSApplication.shared
app.setActivationPolicy(.accessory)      // no Dock icon, like LSUIElement
let controller = IslandController()
controller.start()

// Self-check that does not need Screen Recording permission: ask the window
// server whether our window is on screen, where, and at which layer.
DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
    for (i, s) in NSScreen.screens.enumerated() {
        print("screen[\(i)] \(s.localizedName) frame=\(s.frame) visibleFrame=\(s.visibleFrame) scale=\(s.backingScaleFactor)")
    }
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let mine = list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == ProcessInfo.processInfo.processIdentifier }
    for w in mine {
        print("window-server: onscreen=true layer=\(w[kCGWindowLayer as String] ?? "?") bounds=\(w[kCGWindowBounds as String] ?? "?") alpha=\(w[kCGWindowAlpha as String] ?? "?")")
    }
    if mine.isEmpty { print("window-server: our window is NOT on screen") }
}
app.run()
