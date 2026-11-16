import AppKit

// Topside: an LSUIElement app (no Dock icon). The island is a panel at the top
// of the screen; a menu bar icon is the fallback way in (design doc 8.7).

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
