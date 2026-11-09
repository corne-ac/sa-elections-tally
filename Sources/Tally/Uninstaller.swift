import AppKit
import ServiceManagement

/// Removes Tally and everything it can leave on this Mac. Used by the in-app
/// "Uninstall Tally…" command and by `Tally --uninstall` (which scripts/uninstall.sh calls).
///
/// Only ever touches paths named after Tally's own bundle id or executable name.
enum Uninstaller {
    static let bundleID = Bundle.main.bundleIdentifier ?? "local.tally.sa-elections"

    /// Returns a human-readable log of what was removed.
    @discardableResult
    static func run(removeApp: Bool) -> [String] {
        var log: [String] = []
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let library = home.appendingPathComponent("Library")

        // 1. Login item (Background Task Management)
        let service = SMAppService.mainApp
        if service.status == .enabled || service.status == .requiresApproval {
            if (try? service.unregister()) != nil { log.append("Removed login item") }
        }

        // 2. Preferences (through cfprefsd, then the file itself)
        UserDefaults.standard.removePersistentDomain(forName: bundleID)
        UserDefaults.standard.synchronize()
        runTool("/usr/bin/defaults", ["delete", bundleID])

        // 3. Support files
        var targets = [
            "Preferences/\(bundleID).plist",
            "Caches/\(bundleID)",
            "HTTPStorages/\(bundleID)",
            "HTTPStorages/\(bundleID).binarycookies",
            "Saved Application State/\(bundleID).savedState",
            "Application Support/\(bundleID)",
            "WebKit/\(bundleID)",
        ].map { library.appendingPathComponent($0) }
        targets += matching(in: library.appendingPathComponent("Logs/DiagnosticReports"), prefix: "Tally-")
        targets += matching(in: library.appendingPathComponent("Logs/DiagnosticReports"), prefix: "Tally_")
        targets += matching(in: library.appendingPathComponent("Application Support/CrashReporter"), prefix: "Tally_")
        for url in targets where fm.fileExists(atPath: url.path) {
            if (try? fm.removeItem(at: url)) != nil {
                log.append("Removed ~/" + url.path.replacingOccurrences(of: home.path + "/", with: ""))
            }
        }

        // 4. The app bundle itself (guarded: only a bundle named Tally.app with our bundle id)
        if removeApp {
            let app = Bundle.main.bundleURL
            if app.lastPathComponent == "Tally.app", Bundle.main.bundleIdentifier == bundleID {
                runTool("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister",
                        ["-u", app.path])
                if (try? fm.removeItem(at: app)) != nil { log.append("Removed \(app.path)") }
            }
        }
        return log
    }

    /// In-app flow: confirm, uninstall, say goodbye, quit.
    @MainActor
    static func confirmAndRun() {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall Tally?"
        alert.informativeText = "This quits Tally and deletes the app, its settings, its offline cache, its login item and any crash logs. Nothing else on your Mac is touched.\n\nThe source folder you built it from is left alone."
        alert.addButton(withTitle: "Uninstall")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let log = run(removeApp: true)
        let done = NSAlert()
        done.messageText = "Tally has been removed"
        done.informativeText = log.isEmpty ? "Nothing was left to remove." : log.joined(separator: "\n")
        done.addButton(withTitle: "Quit")
        done.runModal()
        NSApp.terminate(nil)
    }

    private static func matching(in dir: URL, prefix: String) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
    }

    private static func runTool(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}
