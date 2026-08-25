import Cocoa

setvbuf(stdout, nil, _IONBF, 0)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory) // menu bar only, no Dock icon
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
