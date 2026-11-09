import AppKit
import ServiceManagement
import SwiftUI

@main
enum TallyMain {
    @MainActor
    static func main() {
        // `Tally --cleanup` is run by uninstall.sh: removes the login item and preferences, then exits.
        if CommandLine.arguments.contains("--cleanup") {
            Cleanup.run()
            exit(0)
        }
        // `Tally --snapshot <dir>`: dev aid that renders the live dashboard to PNGs, then exits.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            Snapshot.run(outputDir: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        // `Tally --uninstall`: removes the app and everything it wrote (no UI). Used by scripts/uninstall.sh.
        if CommandLine.arguments.contains("--uninstall") {
            let log = Uninstaller.run(removeApp: true)
            print(log.isEmpty ? "  nothing to remove" : log.map { "  " + $0 }.joined(separator: "\n"))
            exit(0)
        }
        // Single instance: a second launch (say, login item plus a manual open) quietly exits.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)   // menu bar only: no Dock icon, no app switcher entry
        app.run()
    }
}

// MARK: - Preferences

enum MenuBarStyle: String, CaseIterable, Identifiable {
    case share, margin, duel
    var id: String { rawValue }
    var title: String {
        switch self {
        case .share: return "Leader & share — ANC 32.0%"
        case .margin: return "Leader & margin — ANC +5.0"
        case .duel: return "Top two — ANC 32 · DA 27"
        }
    }
}

enum Prefs {
    static let menuBarStyle = "menuBarStyle"
    static let showProgress = "menuBarShowProgress"
    static let showDot = "menuBarShowDot"
    static let showMonitor = "showResourceMonitor"

    static func register() {
        UserDefaults.standard.register(defaults: [
            menuBarStyle: MenuBarStyle.share.rawValue,
            showProgress: false,
            showDot: true,
            showMonitor: true,
        ])
    }
}

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Tally: login item change failed: \(error.localizedDescription)")
        }
    }
}

enum Cleanup {
    static func run() {
        let service = SMAppService.mainApp
        // .notFound / .notRegistered mean there is nothing to remove; unregister() would throw.
        if service.status == .enabled || service.status == .requiresApproval {
            do {
                try service.unregister()
                print("  login item removed")
            } catch {
                print("  login item: \(error.localizedDescription)")
            }
        } else {
            print("  no login item registered")
        }
        if let id = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: id)
            UserDefaults.standard.synchronize()
        }
    }
}

// MARK: - Memory hygiene

enum Memory {
    /// Hands freed heap pages back to macOS. Parsing a big municipality file (Johannesburg is 17.5 MB)
    /// leaves the allocator holding tens of MB it no longer uses; without this, Activity Monitor keeps
    /// showing them until the system comes under memory pressure.
    @MainActor
    static func relieveSoon(after seconds: Double = 1.5) {
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(seconds))
            malloc_zone_pressure_relief(nil, 0)
        }
    }
}

// MARK: - App delegate: status item + popover

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let store = ElectionStore()
    private lazy var monitor = ResourceMonitor(meter: store.api.meter, cache: store.api.cache)
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    /// Holds the dashboard only while it is open. When closed it holds an empty view, so no SwiftUI
    /// animation, timer or layout can run in the background (and its memory is returned).
    private let host = NSHostingController(rootView: AnyView(EmptyView()))
    private var defaultsObserver: NSObjectProtocol?
    private var debugObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeft
            button.toolTip = "SA Municipal Elections 2026 — live IEC results"
        }

        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        store.onChange = { [weak self] in self?.renderStatusItem() }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderStatusItem() }
        }

        renderStatusItem()
        store.start()

        // Dev-only UI check hook. Inactive unless launched with TALLY_DEBUG_HOOKS=1, e.g.
        //   open --env TALLY_DEBUG_HOOKS=1 ~/Applications/Tally.app
        // then post the distributed notification "local.tally.debug" with object "show:map", "drill:P3",
        // "drill:3003:79800023" or "close". It only opens/closes the dashboard; it never changes data.
        if ProcessInfo.processInfo.environment["TALLY_DEBUG_HOOKS"] == "1" {
            debugObserver = DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("local.tally.debug"), object: nil, queue: .main
            ) { [weak self] note in
                let command = note.object as? String ?? ""
                MainActor.assumeIsolated { self?.debugCommand(command) }
            }
        }
    }

    // MARK: Clicks

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickMenu()
        } else {
            togglePopover(sender)
        }
    }

    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate()
        host.rootView = AnyView(DashboardView(
            store: store, monitor: monitor,
            onQuit: { NSApp.terminate(nil) },
            onUninstall: { [weak self] in self?.uninstall() },
            initialTab: DashboardView.Tab(rawValue: store.lastTab) ?? .parties))
        host.view.layoutSubtreeIfNeeded()
        popover.contentSize = host.view.fittingSize
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showQuickMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open IEC results dashboard", action: #selector(openIEC), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Uninstall Tally…", action: #selector(uninstall), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Tally", action: #selector(quit), keyEquivalent: "q").target = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil   // keep left-click for the popover
    }

    private func debugCommand(_ command: String) {
        let parts = command.split(separator: ":").map(String.init)
        let tabName = parts.first == "drill" ? "map" : (parts.count > 1 ? parts[1] : "")
        if let tab = DashboardView.Tab.allCases.first(where: { $0.rawValue.lowercased() == tabName.lowercased() }) {
            store.lastTab = tab.rawValue
        }
        switch parts.first {
        case "close":
            popover.performClose(nil)
        case "show":
            if !popover.isShown, let button = statusItem.button { togglePopover(button) }
            store.requestedTab = parts.count > 1 ? parts[1] : nil
        case "drill":
            if !popover.isShown, let button = statusItem.button { togglePopover(button) }
            store.requestedTab = "map"
            if parts.count > 1, parts[1].hasPrefix("P"), let p = Int(parts[1].dropFirst()) {
                store.drill.openProvince(p)
            } else if parts.count > 1, let m = Int(parts[1]) {
                store.drill.openMunicipality(m)
                if parts.count > 2, let w = Int(parts[2]) { store.drill.openWard(w) }
            } else {
                store.drill.goNational()
            }
        default:
            break
        }
    }

    @objc private func refreshNow() { store.refreshNow() }
    @objc private func uninstall() {
        popover.performClose(nil)
        Uninstaller.confirmAndRun()
    }

    // MARK: Popover visibility drives the expensive bits

    func popoverDidShow(_ notification: Notification) {
        store.dashboardVisible = true
        store.drill.setActive(true)
        monitor.start()
    }

    func popoverDidClose(_ notification: Notification) {
        store.dashboardVisible = false
        store.drill.setActive(false)      // stops drill-down refreshes and frees its memory
        monitor.stop()
        host.rootView = AnyView(EmptyView())   // tear the dashboard down: nothing animates while closed
        Memory.relieveSoon()
    }
    @objc private func openIEC() { NSWorkspace.shared.open(ResultsAPI.dashboardURL) }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Menu bar label

    private func renderStatusItem() {
        guard let button = statusItem?.button else { return }
        let defaults = UserDefaults.standard
        let (title, dotColor) = Self.statusTitle(
            store: store,
            style: MenuBarStyle(rawValue: defaults.string(forKey: Prefs.menuBarStyle) ?? "") ?? .share,
            showDot: defaults.bool(forKey: Prefs.showDot),
            showProgress: defaults.bool(forKey: Prefs.showProgress))
        button.attributedTitle = title
        button.image = dotColor.map { Self.dot($0) }
        button.imageHugsTitle = true
        button.toolTip = Self.tooltip(store: store)
    }

    private static func tooltip(store: ElectionStore) -> String {
        let asOf = store.dataAsOf.map { " (IEC report \($0.formatted(date: .omitted, time: .shortened)))" } ?? ""
        switch store.state {
        case .offline: return "Tally — offline, showing saved results" + asOf
        case .error: return "Tally — can’t reach the IEC, showing last good results" + asOf
        case .awaiting: return "Tally — awaiting 2026 results"
        default: return "Tally — SA Municipal Elections 2026, live IEC results" + asOf
        }
    }

    static func statusTitle(store: ElectionStore, style: MenuBarStyle, showDot: Bool, showProgress: Bool) -> (NSAttributedString, NSColor?) {

        let size = NSFont.systemFontSize
        let bold = NSFont.systemFont(ofSize: size, weight: .semibold)
        let digits = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        let small = NSFont.monospacedDigitSystemFont(ofSize: size - 2, weight: .medium)
        let primary: [NSAttributedString.Key: Any] = [.font: bold, .foregroundColor: NSColor.labelColor]
        let number: [NSAttributedString.Key: Any] = [.font: digits, .foregroundColor: NSColor.labelColor]
        let muted: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: NSColor.secondaryLabelColor]

        let title = NSMutableAttributedString()
        var dotColor: NSColor?

        if let leader = store.leader {
            let catalog = store.catalog
            let abbr = String(catalog.abbr(leader.id, ballotName: leader.name).prefix(8))
            dotColor = catalog.nsColor(leader.id, ballotName: leader.name)
            title.append(NSAttributedString(string: abbr, attributes: primary))
            switch style {
            case .share:
                title.append(NSAttributedString(string: " " + Fmt.pct(leader.percent), attributes: number))
            case .margin:
                title.append(NSAttributedString(string: " +" + Fmt.num1(store.margin ?? 0), attributes: number))
            case .duel:
                title.append(NSAttributedString(string: " " + Fmt.num0(leader.percent), attributes: number))
                if let second = store.runnerUp {
                    let abbr2 = String(catalog.abbr(second.id, ballotName: second.name).prefix(8))
                    title.append(NSAttributedString(string: " · ", attributes: muted))
                    title.append(NSAttributedString(string: abbr2, attributes: primary))
                    title.append(NSAttributedString(string: " " + Fmt.num0(second.percent), attributes: number))
                }
            }
            if showProgress, let p = store.national?.progress {
                title.append(NSAttributedString(string: "  · " + Fmt.num0(p.percVDs) + "% in", attributes: muted))
            }
            if store.isShowingStaleData {
                // Dim the whole label and mark it, so stale numbers never pass for live ones.
                title.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                   range: NSRange(location: 0, length: title.length))
                title.append(NSAttributedString(string: store.state == .offline ? " ⌁" : " ⚠︎", attributes: muted))
            }
        } else {
            switch store.state {
            case .awaiting: title.append(NSAttributedString(string: "LGE awaiting", attributes: number))
            case .error: title.append(NSAttributedString(string: "LGE ⚠︎", attributes: number))
            case .offline: title.append(NSAttributedString(string: "LGE offline", attributes: number))
            default: title.append(NSAttributedString(string: "LGE …", attributes: number))
            }
        }

        return (title, showDot ? dotColor : nil)
    }

    /// A small non-template coloured circle so the party colour survives menu bar tinting.
    static func dot(_ color: NSColor) -> NSImage {
        let size = NSSize(width: 8, height: 8)
        let image = NSImage(size: size, flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
