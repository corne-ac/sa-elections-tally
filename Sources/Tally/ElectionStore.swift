import AppKit
import Foundation
import Network
import Observation

enum FeedState: Equatable {
    case loading
    case live
    case awaiting
    case offline                 // no network path
    case error(String)           // network up, but the IEC could not be reached or sent bad data
}

/// Single source of truth for the UI, and the scheduler that decides when to talk to the IEC.
///
/// Failsafe behaviour:
/// - Starts from the offline cache, so results show instantly even with no connection.
/// - Watches the network path: stops polling when offline, refreshes the moment it returns.
/// - Pauses across system sleep and refreshes shortly after wake.
/// - Backs off exponentially (1 → 2 → 4 → 8 → 10 min) while the IEC is unreachable or sends bad data,
///   and always keeps showing the last good results.
///
/// Lightweight behaviour:
/// - Background polling fetches only the national file (a 304 with no body when unchanged).
/// - Province files are fetched only while the dashboard is open.
/// - Polls every 60 s during the count, 5 min while awaiting results, 15 min once the count is final,
///   and doubles intervals in Low Power Mode. Timers carry tolerance so macOS can coalesce wake-ups.
@MainActor @Observable
final class ElectionStore {
    private(set) var national: NationalResult?
    private(set) var provinceDetail: [Int: ProvinceResult] = [:]
    private(set) var municipalities: [Int: MunicipalityResult] = [:]
    private(set) var baseline: [Int: Double] = [:]                 // party id → 2021 national %
    private(set) var baselineProvince: [Int: [Int: Double]] = [:]  // province id → party id → 2021 %
    private(set) var catalog = PartyCatalog()
    private(set) var state: FeedState = .loading
    /// Last time the IEC answered (200 or 304).
    private(set) var lastContact: Date?
    /// When the shown data came from the offline cache, the time it was saved.
    private(set) var cacheSavedAt: Date?
    private(set) var isRefreshing = false
    private(set) var isOnline = true
    private(set) var nextRefreshAt: Date?
    private(set) var consecutiveFailures = 0
    /// National shares at the previous distinct IEC report, for "since last update" movement.
    private(set) var previousShares: [Int: Double] = [:]
    /// Voting districts counted, sampled whenever the IEC publishes a new report (this session only).
    @ObservationIgnored private var progressSamples: [(date: Date, done: Int)] = []
    /// Dev hook (TALLY_DEBUG_HOOKS): asks the dashboard to switch to a tab by name.
    var requestedTab: String?
    /// The tab you last looked at, so reopening the dashboard returns to it.
    @ObservationIgnored var lastTab = "Parties"

    var dashboardVisible = false {
        didSet { if dashboardVisible && !oldValue { refreshIfStale() } }
    }

    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored let api = ResultsAPI()
    /// Municipality → ward → voting-station drill-down for the map (loads only on demand).
    @ObservationIgnored private(set) lazy var drill = DrillDown(store: self)
    @ObservationIgnored private var nextTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    @ObservationIgnored private var rerunRequested = false
    @ObservationIgnored private var catalogLoaded = false
    @ObservationIgnored private var baselineLoaded = false
    @ObservationIgnored private var lastProvinceFetch: Date?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var isAsleep = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        startPathMonitor()
        observeSleepWake()
        Task {
            await loadCache()
            schedule(after: 0)
        }
    }

    /// One cache load plus one full refresh, without the scheduler (used by `--snapshot`).
    func refreshOnceForSnapshot() async {
        await loadCache()
        await refresh(includeProvinces: true)
    }

    /// Called when the dashboard opens.
    func refreshIfStale() {
        let age = lastContact.map { Date().timeIntervalSince($0) } ?? .infinity
        let provinceAge = lastProvinceFetch.map { Date().timeIntervalSince($0) } ?? .infinity
        if age > 30 || provinceAge > 60 { schedule(after: 0) }
    }

    /// Manual refresh: ignores backoff.
    func refreshNow() {
        consecutiveFailures = 0
        schedule(after: 0)
    }

    // MARK: Scheduling

    private func schedule(after seconds: Double) {
        if isRefreshing {
            // Never cancel an in-flight refresh; run again as soon as it finishes instead.
            rerunRequested = true
            return
        }
        nextTask?.cancel()
        nextRefreshAt = Date().addingTimeInterval(seconds)
        nextTask = Task { [weak self] in
            if seconds > 0 {
                try? await Task.sleep(for: .seconds(seconds), tolerance: .seconds(max(1, seconds * 0.1)))
            }
            guard !Task.isCancelled, let self else { return }
            await self.tick()
        }
    }

    private func tick() async {
        guard !isAsleep else { nextRefreshAt = nil; return }               // resumed by didWake
        guard isOnline else { state = .offline; nextRefreshAt = nil; onChange?(); return }   // resumed by path monitor
        let provinceAge = lastProvinceFetch.map { Date().timeIntervalSince($0) } ?? .infinity
        await refresh(includeProvinces: dashboardVisible && provinceAge > 50)
        if rerunRequested {
            // Something asked for a refresh while this one ran. tick() re-checks sleep and connectivity,
            // so this never polls while asleep or offline.
            rerunRequested = false
            schedule(after: 0)
        } else if !Task.isCancelled {
            schedule(after: nextInterval())
        }
        // Cancelled by sleep or going offline: didWake / the path monitor reschedule.
    }

    private func nextInterval() -> Double {
        var interval: Double
        switch state {
        case .error, .offline:
            interval = min(600, 60 * pow(2, Double(max(0, consecutiveFailures - 1))))
        case .awaiting:
            interval = 300
        default:
            interval = (national?.progress.isComplete ?? false) ? 900 : 60
        }
        if ProcessInfo.processInfo.isLowPowerModeEnabled { interval *= 2 }
        return interval
    }

    // MARK: Fetching

    private func refresh(includeProvinces: Bool) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        onChange?()
        defer {
            isRefreshing = false
            onChange?()
        }

        let api = self.api
        let needCatalog = !catalogLoaded
        let needBaseline = !baselineLoaded

        async let nationalTask = api.national()
        async let catalogTask: Fetched<[PartyListEntry]>? = needCatalog ? (try? await api.partyList()) : nil
        async let baselineTask: Fetched<NationalResult>? = needBaseline ? (try? await api.baseline()) : nil

        do {
            if case .updated(let result) = try await nationalTask { apply(result) }
            state = .live
            lastContact = Date()
            cacheSavedAt = nil
            consecutiveFailures = 0
        } catch is CancellationError {
            // Sleep, going offline or quitting interrupted the request: not a failure.
        } catch let error as ResultsError {
            consecutiveFailures += 1
            switch error {
            case .awaitingResults:
                if national == nil { state = .awaiting } else { state = .live }
                consecutiveFailures = 0
            case .offline:
                state = .offline
            default:
                state = .error(error.localizedDescription)
            }
        } catch {
            consecutiveFailures += 1
            state = .error(error.localizedDescription)
        }

        switch await catalogTask {
        case .updated(let list)?: catalog = PartyCatalog(partyList: list); catalogLoaded = true
        case .unchanged?: catalogLoaded = true
        case nil: break
        }
        switch await baselineTask {
        case .updated(let base)?: applyBaseline(base); baselineLoaded = true
        case .unchanged?: baselineLoaded = true
        case nil: break
        }

        if state == .live && includeProvinces { await refreshProvinces() }
    }

    private func refreshProvinces() async {
        let api = self.api
        let (results, anyAnswered) = await withTaskGroup(of: Fetched<ProvinceResult>?.self) { group in
            for id in 1...9 { group.addTask { try? await api.province(id) } }
            var updated: [ProvinceResult] = []
            var answered = false
            for await r in group {
                switch r {
                case .updated(let p)?: updated.append(p); answered = true
                case .unchanged?: answered = true
                case nil: break
                }
            }
            return (updated, answered)
        }
        for r in results { provinceDetail[r.id] = r }
        if !results.isEmpty { rebuildMunicipalityIndex() }
        if anyAnswered { lastProvinceFetch = Date() }
    }

    private func loadCache() async {
        let api = self.api
        if let cached = await api.cachedNational() {
            national = cached.value
            cacheSavedAt = cached.savedAt
        }
        for id in 1...9 {
            if let cached = await api.cached(await api.provincePath(id), as: ProvinceResult.self) {
                provinceDetail[id] = cached.value
            }
        }
        if let cached = await api.cached(await api.baselinePath, as: NationalResult.self) {
            applyBaseline(cached.value)
            baselineLoaded = true          // 2021 is final: never refetched once cached
        }
        if let cached = await api.cached(api.partyListPath, as: [PartyListEntry].self) {
            catalog = PartyCatalog(partyList: cached.value)   // still revalidated once per launch (cheap 304)
        }
        rebuildMunicipalityIndex()
        onChange?()
    }

    private func apply(_ result: NationalResult) {
        let when = result.reportDate ?? Date()
        if progressSamples.last?.done != result.progress.vdsComplete {
            progressSamples.append((when, result.progress.vdsComplete))
            progressSamples.removeAll { when.timeIntervalSince($0.date) > 3 * 3600 }   // keep the last 3 hours
        }
        if let old = national, old.reportDate != result.reportDate {
            previousShares = Dictionary(old.parties.map { ($0.id, $0.percent) }, uniquingKeysWith: { a, _ in a })
        }
        national = result
        rebuildMunicipalityIndex()
    }

    private func applyBaseline(_ base: NationalResult) {
        baseline = Dictionary(base.parties.map { ($0.id, $0.percent) }, uniquingKeysWith: { a, _ in a })
        for p in base.provinces {
            baselineProvince[p.id] = Dictionary(p.parties.map { ($0.id, $0.percent) }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// One lookup table for the map and metro cards; province files (top three parties) win over the
    /// national summary (top one or two) when they are at least as recent.
    private func rebuildMunicipalityIndex() {
        var index: [Int: MunicipalityResult] = [:]
        for p in national?.provinces ?? [] { for m in p.municipalities { index[m.id] = m } }
        for p in provinceDetail.values { for m in p.municipalities { index[m.id] = m } }
        municipalities = index
    }

    // MARK: Network and power awareness

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "tally.path", qos: .utility))
        pathMonitor = monitor
    }

    private func networkChanged(online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        if online {
            consecutiveFailures = 0
            schedule(after: 2)            // give DNS/DHCP a moment
        } else {
            nextTask?.cancel()
            nextRefreshAt = nil
            state = .offline
            onChange?()
        }
    }

    private func observeSleepWake() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAsleep = true
                self?.nextTask?.cancel()
                self?.nextRefreshAt = nil
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isAsleep = false
                self?.schedule(after: 5)
            }
        })
    }

    // MARK: Derived values

    /// Parties by vote share, with the aggregated "Other" bucket last.
    func ranked(_ parties: [PartyResult]) -> [PartyResult] {
        parties.sorted { a, b in
            if a.isAggregate != b.isAggregate { return !a.isAggregate }
            return a.percent > b.percent
        }
    }

    var rankedNational: [PartyResult] { ranked(national?.parties ?? []) }
    var leader: PartyResult? { rankedNational.first { !$0.isAggregate } }
    var runnerUp: PartyResult? { rankedNational.filter { !$0.isAggregate }.dropFirst().first }
    var margin: Double? {
        guard let l = leader, let r = runnerUp else { return nil }
        return l.percent - r.percent
    }

    func swing(_ id: Int) -> Double? {
        guard let current = national?.parties.first(where: { $0.id == id }), let old = baseline[id] else { return nil }
        return current.percent - old
    }

    func provinceSwing(_ provinceID: Int, party: PartyResult) -> Double? {
        guard let old = baselineProvince[provinceID]?[party.id] else { return nil }
        return party.percent - old
    }

    func movement(_ id: Int) -> Double? {
        guard let current = national?.parties.first(where: { $0.id == id }), let old = previousShares[id] else { return nil }
        return current.percent - old
    }

    /// Province with its full party list when the detail file has loaded, else the national summary.
    func province(_ id: Int) -> ProvinceResult? {
        provinceDetail[id] ?? national?.provinces.first { $0.id == id }
    }

    var provinces: [ProvinceResult] { (1...9).compactMap { province($0) } }
    var metros: [MunicipalityResult] { Metro.ids.compactMap { municipalities[$0] } }

    /// Counting pace over the last hour or so, in voting districts per hour. Needs at least
    /// 15 minutes of reports seen by this session; nil until then (it is an estimate, not IEC data).
    var countingPace: Double? {
        guard let last = progressSamples.last else { return nil }
        let window = progressSamples.filter { last.date.timeIntervalSince($0.date) <= 90 * 60 }
        guard let first = window.first else { return nil }
        let hours = last.date.timeIntervalSince(first.date) / 3600
        guard hours >= 0.25, last.done > first.done else { return nil }
        return Double(last.done - first.done) / hours
    }

    /// Ballot totals at national level (repeated on each party row by the IEC).
    var ballots: PartyResult? { national?.parties.first }

    /// True when what is on screen did not come from a successful contact in the last few minutes.
    var isShowingStaleData: Bool {
        guard national != nil else { return false }
        switch state {
        case .offline, .error: return true
        case .loading: return cacheSavedAt != nil
        default: return false
        }
    }

    /// The best "as of" time for what is on screen.
    var dataAsOf: Date? { national?.reportDate ?? cacheSavedAt }
}
