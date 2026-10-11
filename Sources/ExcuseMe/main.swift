import AppKit
import ExcuseMeKit

if CLI.isRequested { CLI.run() }
if CLI.isDemoRequested { MainActor.assumeIsolated { CLI.runDemo() } }

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
