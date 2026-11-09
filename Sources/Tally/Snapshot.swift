import AppKit
import SwiftUI

/// Dev aid: `Tally --snapshot <dir>` fetches live data, renders every dashboard tab (light and dark)
/// plus each menu bar style to PNG files in <dir>, then exits. Never reads or writes preferences.
@MainActor
enum Snapshot {
    static func run(outputDir: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Prefs.register()
        let store = ElectionStore()

        Task { @MainActor in
            await store.refreshOnceForSnapshot()
            // TALLY_SNAPSHOT_DRILL="3003" or "3003:79800023" renders the Map tab drilled into a municipality / ward.
            if let spec = ProcessInfo.processInfo.environment["TALLY_SNAPSHOT_DRILL"], spec.hasPrefix("P"),
               let province = Int(spec.dropFirst()) {
                await store.drill.openAndWait(province: province)      // "P3" = Gauteng
            } else if let spec = ProcessInfo.processInfo.environment["TALLY_SNAPSHOT_DRILL"] {
                let parts = spec.split(separator: ":").compactMap { Int($0) }
                if let munic = parts.first {
                    let t0 = Date()
                    await store.drill.openAndWait(munic: munic, ward: parts.count > 1 ? parts[1] : nil)
                    print("drill munic=\(munic) ward=\(parts.count > 1 ? parts[1] : 0) loaded in \(Int(Date().timeIntervalSince(t0) * 1000)) ms: wards=\(store.drill.wardShapes.count) results=\(store.drill.wards.count) stationsShapes=\(store.drill.stationShapes.count) inWard=\(store.drill.stationShapesInWard.count) names=\(store.drill.stationNames.count) leaders=\(store.drill.leaders.count) problem=\(store.drill.problem ?? "none")")
                }
            }
            let monitor = ResourceMonitor(meter: store.api.meter, cache: store.api.cache)
            monitor.start()
            try? await Task.sleep(for: .seconds(2.2))
            try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for tab in DashboardView.Tab.allCases {
                    let url = outputDir.appendingPathComponent("dashboard-\(tab.rawValue.lowercased())-\(name).png")
                    await render(DashboardView(store: store, monitor: monitor, onQuit: {}, onUninstall: {}, initialTab: tab), appearance: appearance, to: url)
                }
                if ProcessInfo.processInfo.environment["TALLY_SNAPSHOT_DRILL"] != nil {
                    // The whole Map tab without the scroll viewport, to see the ward panel and station list.
                    let full = MapTab(store: store).padding(14).frame(width: 400)
                    await render(full, appearance: appearance, to: outputDir.appendingPathComponent("maptab-full-\(name).png"))
                }
                for style in MenuBarStyle.allCases {
                    for progress in [false, true] {
                        let (title, dot) = AppDelegate.statusTitle(store: store, style: style, showDot: true, showProgress: progress)
                        let file = "menubar-\(style.rawValue)\(progress ? "-progress" : "")-\(name).png"
                        renderMenuBar(title: title, dot: dot, appearance: appearance, to: outputDir.appendingPathComponent(file))
                    }
                }
            }
            print("bytes=\(store.api.meter.snapshot.bytes) requests=\(store.api.meter.snapshot.requests) unchanged=\(store.api.meter.snapshot.unchanged) failures=\(store.api.meter.snapshot.failures) cacheSavedAt=\(String(describing: store.cacheSavedAt)) municipalities=\(store.municipalities.count)")
            print("state=\(store.state) leader=\(store.leader.map { "\($0.id) \($0.percent)" } ?? "none") provinces=\(store.provinceDetail.count) catalogANC=\(store.catalog.abbr(7)) baselineANC=\(store.baseline[7] ?? -1)")
            print("Snapshots written to \(outputDir.path)")
            exit(0)
        }
        app.run()
    }

    private static func render<V: View>(_ view: V, appearance: NSAppearance.Name, to url: URL) async {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = NSAppearance(named: appearance)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false   // ARC owns it; the AppKit default would double-free
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(900))   // let layout and initial animations settle
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.close()
    }

    private static func renderMenuBar(title: NSAttributedString, dot: NSColor?, appearance: NSAppearance.Name, to url: URL) {
        let scale: CGFloat = 2
        let textSize = title.size()
        let dotWidth: CGFloat = dot == nil ? 0 : 12
        let size = NSSize(width: ceil(textSize.width + dotWidth + 24), height: 24)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            (appearance == .darkAqua ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(origin: .zero, size: size).fill()
            var x: CGFloat = 12
            if let dot {
                AppDelegate.dot(dot).draw(in: NSRect(x: x, y: (size.height - 8) / 2, width: 8, height: 8))
                x += dotWidth
            }
            title.draw(at: NSPoint(x: x, y: (size.height - textSize.height) / 2))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
