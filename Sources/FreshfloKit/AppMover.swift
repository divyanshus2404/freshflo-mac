import AppKit

/// Running Freshflo from the disk image or the Downloads folder breaks things for new users: macOS runs it from a
/// temporary read-only copy ("App Translocation"), so permissions don't stick and updates can't install.
/// On launch, offer to move it into Applications and relaunch from there.
@MainActor
enum AppMover {
    static func moveIfNeeded() {
        let bundle = Bundle.main.bundleURL
        let path = bundle.path
        guard bundle.pathExtension == "app" else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") { return }
        if path.contains("/build/Freshflo.app") { return } // local development builds

        let alert = NSAlert()
        alert.messageText = "Move Freshflo to Applications?"
        alert.informativeText = "Freshflo needs to live in your Applications folder so macOS remembers its permissions and updates can install."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let destination = URL(fileURLWithPath: "/Applications/Freshflo.app")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                // An older copy: quit it if it's running, then put it in the Trash.
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.freshflo.app")
                    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
                    .forEach { $0.terminate() }
                try FileManager.default.trashItem(at: destination, resultingItemURL: nil)
            }
            try run("/usr/bin/ditto", [path, destination.path])
            // The person already chose to open this copy, so the moved one shouldn't ask again.
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", destination.path])
            // Leave nothing behind in Downloads (a disk image or translocated copy is read-only, so skip those).
            if !path.hasPrefix("/Volumes/"), !path.contains("/AppTranslocation/") {
                try? FileManager.default.trashItem(at: bundle, resultingItemURL: nil)
            }
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(destination.path)\""]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Couldn't move Freshflo"
            failed.informativeText = "Drag Freshflo into your Applications folder yourself, then open it from there."
            failed.runModal()
        }
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw CocoaError(.fileWriteUnknown) }
    }
}
