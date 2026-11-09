import Darwin
import Foundation
import Observation
import SwiftUI

/// Tally's own footprint, measured from inside the process.
///
/// Samples every 2 s **only while the dashboard is open**; with the dashboard closed it does
/// nothing at all. The network counters come from URLSession task metrics, so they count real
/// compressed bytes on the wire (bodies and headers), not decompressed JSON.
@MainActor @Observable
final class ResourceMonitor {
    struct Sample: Identifiable { let id: Int; let cpu: Double; let memoryMB: Double }

    private(set) var cpuPercent = 0.0
    private(set) var memoryBytes: UInt64 = 0
    private(set) var averageCPU = 0.0             // since launch
    private(set) var totalCPUSeconds = 0.0
    private(set) var wakeupsPerMinute = 0.0
    private(set) var history: [Sample] = []
    private(set) var network = NetworkMeter.Stats()
    private(set) var cacheBytes: Int64 = 0

    @ObservationIgnored private let meter: NetworkMeter
    @ObservationIgnored private let cache: DiskCache
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastCPU = 0.0
    @ObservationIgnored private var lastWakeups: UInt64 = 0
    @ObservationIgnored private var lastTime = Date()
    @ObservationIgnored private var sampleID = 0
    @ObservationIgnored private let launched = Date()

    static let interval = 2.0
    static let historyLength = 60                 // two minutes

    init(meter: NetworkMeter, cache: DiskCache) {
        self.meter = meter
        self.cache = cache
    }

    var uptime: TimeInterval { Date().timeIntervalSince(launched) }
    var memoryMB: Double { Double(memoryBytes) / 1_048_576 }

    func start() {
        guard task == nil else { return }
        lastCPU = Self.cpuSeconds()
        lastWakeups = Self.usage()?.ri_pkg_idle_wkups ?? 0
        lastTime = Date()
        sample(updateRates: false)
        cacheBytes = cache.sizeOnDisk
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.interval), tolerance: .milliseconds(500))
                guard !Task.isCancelled else { return }
                self?.sample(updateRates: true)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func sample(updateRates: Bool) {
        let now = Date()
        let cpu = Self.cpuSeconds()
        let usage = Self.usage()
        let wall = now.timeIntervalSince(lastTime)
        if updateRates, wall > 0 {
            cpuPercent = max(0, (cpu - lastCPU) / wall * 100)
            let wakeups = usage?.ri_pkg_idle_wkups ?? 0
            wakeupsPerMinute = Double(wakeups &- lastWakeups) / wall * 60
            lastWakeups = wakeups
        }
        lastCPU = cpu
        lastTime = now
        totalCPUSeconds = cpu
        averageCPU = uptime > 0 ? cpu / uptime * 100 : 0
        memoryBytes = usage?.ri_phys_footprint ?? 0       // the "Memory" column in Activity Monitor
        network = meter.snapshot

        sampleID += 1
        history.append(Sample(id: sampleID, cpu: cpuPercent, memoryMB: memoryMB))
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
        if sampleID % 15 == 0 { cacheBytes = cache.sizeOnDisk }
    }

    // MARK: Darwin probes

    private static func cpuSeconds() -> Double {
        var r = rusage()
        guard getrusage(RUSAGE_SELF, &r) == 0 else { return 0 }
        let user = Double(r.ru_utime.tv_sec) + Double(r.ru_utime.tv_usec) / 1_000_000
        let system = Double(r.ru_stime.tv_sec) + Double(r.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private static func usage() -> rusage_info_v4? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info : nil
    }
}

// MARK: - UI

/// Compact footprint readout for the footer: CPU · memory · data used · connection.
/// Click it to show the detailed panel (charts and counters).
struct ResourceMeter: View {
    let monitor: ResourceMonitor
    let store: ElectionStore
    @Binding var expanded: Bool

    var body: some View {
        Button {
            withAnimation(.snappy) { expanded.toggle() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 9.5, weight: .semibold))
                Metric(label: "", value: Fmt.num1(monitor.cpuPercent) + "%")
                Metric(label: "", value: Fmt.num0(monitor.memoryMB) + " MB")
                Metric(label: "", value: ByteCountFormatter.string(fromByteCount: monitor.network.bytes, countStyle: .file))
                NetworkStatus(store: store, compact: true)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.primary.opacity(expanded ? 0.08 : 0.04)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Tally’s own CPU, memory and data use. Click for details.")
    }
}

/// The expanded resource monitor, shown above the footer.
struct ResourcePanel: View {
    let monitor: ResourceMonitor
    let store: ElectionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(text: "Tally’s footprint")
                Spacer()
                NetworkStatus(store: store, compact: false)
            }
            ResourceDetail(monitor: monitor, store: store)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
    }
}

private struct Metric: View {
    let label: String
    let value: String
    var body: some View {
        HStack(spacing: 3) {
            if !label.isEmpty { Text(label).foregroundStyle(.secondary) }
            Text(value).fontWeight(.medium).monospacedDigit().contentTransition(.numericText())
        }
        .font(.system(size: 10))
    }
}

private struct NetworkStatus: View {
    let store: ElectionStore
    var compact = false
    var body: some View {
        let (icon, color, text): (String, Color, String) = {
            if !store.isOnline { return ("wifi.slash", .secondary, "Offline") }
            if case .error = store.state { return ("exclamationmark.triangle.fill", Theme.hung, "Retrying") }
            return ("wifi", Theme.controlled, "Online")
        }()
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .semibold))
            if !compact { Text(text).font(.system(size: 10, weight: .medium)) }
        }
        .foregroundStyle(color)
        .help(text)
    }
}

struct ResourceDetail: View {
    let monitor: ResourceMonitor
    let store: ElectionStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Sparkline(values: monitor.history.map(\.cpu), title: "CPU", unit: "%", tint: .blue, floor: 5)
                Sparkline(values: monitor.history.map(\.memoryMB), title: "Memory", unit: " MB", tint: .purple, floor: 0)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                GridRow {
                    Detail("Requests", "\(monitor.network.requests)")
                    Detail("Unchanged (304)", "\(monitor.network.unchanged)")
                    Detail("Failed", "\(monitor.network.failures)")
                }
                GridRow {
                    Detail("Avg CPU", monitor.averageCPU.formatted(.number.precision(.fractionLength(2))) + "%")
                    Detail("CPU time", Fmt.num1(monitor.totalCPUSeconds) + " s")
                    Detail("Wake-ups", Fmt.num1(monitor.wakeupsPerMinute) + "/min")
                }
                GridRow {
                    Detail("Offline cache", ByteCountFormatter.string(fromByteCount: monitor.cacheBytes, countStyle: .file))
                    Detail("Uptime", Self.duration(monitor.uptime))
                    NextRefresh(store: store)
                }
            }
            Text("Samples only while this window is open. Background polling fetches one small file a minute; unchanged files cost a 304 with no body.")
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 3600 ? [.hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: t) ?? "—"
    }
}

private struct Detail: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
        }
    }
}

private struct NextRefresh: View {
    let store: ElectionStore
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let text: String = {
                if store.isRefreshing { return "now" }
                guard let next = store.nextRefreshAt else { return store.isOnline ? "paused" : "when online" }
                let s = max(0, Int(next.timeIntervalSince(context.date)))
                return s >= 60 ? "\(s / 60)m \(s % 60)s" : "\(s)s"
            }()
            Detail("Next refresh", text)
        }
    }
}

private struct Sparkline: View {
    let values: [Double]
    let title: String
    let unit: String
    let tint: Color
    let floor: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
                Spacer()
                Text(values.last.map { Fmt.num1($0) + unit } ?? "—")
                    .font(.system(size: 9.5, weight: .semibold)).monospacedDigit()
            }
            Canvas { context, size in
                guard values.count > 1 else { return }
                let lo = unit == "%" ? 0 : (values.min() ?? 0) * 0.98
                let hi = max(values.max() ?? 1, lo + floor, lo + 0.5)
                let step = size.width / CGFloat(ResourceMonitor.historyLength - 1)
                let x0 = size.width - step * CGFloat(values.count - 1)
                var line = Path()
                for (i, v) in values.enumerated() {
                    let p = CGPoint(x: x0 + step * CGFloat(i), y: size.height * (1 - CGFloat((v - lo) / (hi - lo))))
                    if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
                }
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.addLine(to: CGPoint(x: x0, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(Gradient(colors: [tint.opacity(0.35), tint.opacity(0.02)]),
                                                         startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
            }
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.03)))
        }
        .frame(maxWidth: .infinity)
    }
}
