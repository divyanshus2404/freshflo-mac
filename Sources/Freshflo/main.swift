import AppKit
import FreshfloKit

if CLI.isRequested { CLI.run() }
if CLI.isDemoRequested { MainActor.assumeIsolated { CLI.runDemo() } }

LegacyMigration.run()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
