import Foundation
import Observation

/// Country → province → municipality → ward → voting-station drill-down for the map.
///
/// Lightweight by construction:
/// - Nothing is fetched until you open a municipality; voting-district outlines and station names
///   only when you open a ward.
/// - Everything comes from the offline cache first (instant, works offline), then one conditional
///   request revalidates it (a 304 when unchanged).
/// - While you look at a municipality or ward, ward leaders refresh every 60 s (~37 KB or a 304)
///   and the municipality's full results every 2 min. Nothing refreshes once the dashboard closes.
/// - Closing the dashboard releases all drill-down data from memory; reopening reloads it from disk.
@MainActor @Observable
final class DrillDown {
    typealias Level = MapLevel

    private(set) var level: Level = .national
    private(set) var wardShapes: [GeoShape] = []
    private(set) var stationShapes: [GeoShape] = []
    private(set) var wards: [Int: WardDetail] = [:]
    private(set) var leaders: [Int: WardLeaders.Leader] = [:]
    private(set) var stationNames: [Int: String] = [:]
    private(set) var detailAsOf: Date?
    private(set) var loading: Set<Part> = []
    private(set) var problem: String?

    enum Part: Hashable { case wards, stations, results, leaders, names }

    @ObservationIgnored private weak var store: ElectionStore?
    @ObservationIgnored private var loadedMunic: Int?
    @ObservationIgnored private var stationsLoadedFor: Int?
    @ObservationIgnored private var active = false
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var lastResults: Date?
    @ObservationIgnored private var lastLeaders: Date?
    @ObservationIgnored private var revalidated: Set<String> = []

    init(store: ElectionStore) { self.store = store }

    var municID: Int? {
        switch level {
        case .national, .province: return nil
        case .municipality(let m), .ward(let m, _): return m
        }
    }

    /// The province in focus (also known while inside one of its municipalities or wards).
    var provinceID: Int? {
        switch level {
        case .national: return nil
        case .province(let p): return p
        case .municipality(let m), .ward(let m, _): return SAMap.shared?.munic(m)?.parent
        }
    }

    /// True while a municipality or ward is open, i.e. when drill-down data is needed.
    var needsDetail: Bool { municID != nil }

    var wardID: Int? { if case .ward(_, let w) = level { return w } else { return nil } }
    var isLoading: Bool { !loading.isEmpty }

    func ward(_ id: Int) -> WardDetail? { wards[id] }
    func wardShape(_ id: Int) -> GeoShape? { wardShapes.first { $0.id == id } }
    func stationName(_ id: Int) -> String { stationNames[id] ?? "Voting district \(id)" }
    func hasName(_ id: Int) -> Bool { stationNames[id] != nil }

    /// Voting-district shapes inside the open ward.
    var stationShapesInWard: [GeoShape] {
        guard let w = wardID else { return [] }
        return stationShapes.filter { $0.parent == w }
    }

    // MARK: Navigation

    func openProvince(_ id: Int) {
        level = .province(id)
        problem = nil
        loop?.cancel()
        releaseMemory()          // a province view needs nothing beyond the national data
    }

    func openMunicipality(_ id: Int) {
        level = .municipality(id)
        problem = nil
        Task { await load() }
        restartLoop()
    }

    func openWard(_ id: Int) {
        guard let m = municID else { return }
        level = .ward(munic: m, ward: id)
        problem = nil
        Task { await load() }
        restartLoop()
    }

    func goNational() {
        level = .national
        problem = nil
        loop?.cancel()
        releaseMemory()
    }

    func goUp() {
        switch level {
        case .national: break
        case .province: goNational()
        case .municipality:
            if let p = provinceID { openProvince(p) } else { goNational() }
        case .ward(let m, _):
            level = .municipality(m)
            restartLoop()
        }
    }

    /// Popover shown / hidden.
    func setActive(_ on: Bool) {
        active = on
        if on {
            if needsDetail { Task { await load() } }
            restartLoop()
        } else {
            loop?.cancel()
            releaseMemory()
        }
    }

    /// For `--snapshot`: open a level and wait until its data has loaded.
    func openAndWait(province: Int) async {
        active = true
        level = .province(province)
    }

    func openAndWait(munic: Int, ward: Int?) async {
        active = true
        level = ward.map { .ward(munic: munic, ward: $0) } ?? .municipality(munic)
        await load()
    }

    // MARK: Loading

    private func releaseMemory() {
        wardShapes = []
        stationShapes = []
        wards = [:]
        leaders = [:]
        stationNames = [:]
        loadedMunic = nil
        stationsLoadedFor = nil
        lastResults = nil
        lastLeaders = nil
    }

    private func restartLoop() {
        loop?.cancel()
        guard active, needsDetail else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60), tolerance: .seconds(6))
                guard !Task.isCancelled else { return }
                await self?.load()
            }
        }
    }

    private func load() async {
        guard let store, let munic = municID, let map = SAMap.shared else { return }
        let api = store.api
        let grid = map.grid
        let municWidth = map.munic(munic)?.bounds.width ?? 50

        problem = nil
        if loadedMunic != munic {
            wardShapes = []
            stationShapes = []
            wards = [:]
            stationsLoadedFor = nil
            lastResults = nil
            loadedMunic = munic
        }

        await withTaskGroup(of: Void.self) { group in
            if wardShapes.isEmpty {
                group.addTask { await self.loadWardShapes(munic, api: api, grid: grid, tolerance: max(0.004, municWidth / 2500)) }
            }
            if leaders.isEmpty || (lastLeaders.map { Date().timeIntervalSince($0) > 50 } ?? true) {
                group.addTask { await self.loadLeaders(api: api) }
            }
            if wards.isEmpty || (lastResults.map { Date().timeIntervalSince($0) > 110 } ?? true) {
                group.addTask { await self.loadResults(munic, api: api) }
            }
            if wardID != nil {
                if stationsLoadedFor != munic {
                    group.addTask { await self.loadStationShapes(munic, api: api, grid: grid, tolerance: max(0.001, municWidth / 12000)) }
                }
                if stationNames.isEmpty {
                    group.addTask { await self.loadStationNames(api: api) }
                }
            }
        }
    }

    private func loadWardShapes(_ munic: Int, api: ResultsAPI, grid: AlbersGrid, tolerance: Double) async {
        loading.insert(.wards)
        defer { loading.remove(.wards) }
        let path = await api.wardShapesPath(munic)
        let build: @Sendable (GeoFeatureCollection) async -> [GeoShape] = { collection in
            await Task.detached(priority: .userInitiated) {
                GeoBuilder.shapes(from: collection, grid: grid, tolerance: tolerance,
                                  id: { $0.wardID }, parent: { _ in munic }, number: { $0.wardNumber ?? (($0.wardID ?? 0) % 1000) })
            }.value
        }
        if let cached = await api.cachedMap(path, as: GeoFeatureCollection.self) {
            let shapes = await build(cached.value)
            if loadedMunic == munic { wardShapes = shapes }
            if revalidated.contains(path) { return }
        }
        do {
            if case .updated(let fresh) = try await api.wardShapes(munic) {
                let shapes = await build(fresh)
                if loadedMunic == munic { wardShapes = shapes }
            }
            revalidated.insert(path)
        } catch {
            note(error, part: "ward map")
        }
    }

    private func loadStationShapes(_ munic: Int, api: ResultsAPI, grid: AlbersGrid, tolerance: Double) async {
        loading.insert(.stations)
        defer { loading.remove(.stations) }
        let path = await api.stationShapesPath(munic)
        let build: @Sendable (GeoFeatureCollection) async -> [GeoShape] = { collection in
            await Task.detached(priority: .userInitiated) {
                GeoBuilder.shapes(from: collection, grid: grid, tolerance: tolerance,
                                  id: { $0.vdNumber }, parent: { $0.wardID ?? 0 }, number: { _ in 0 })
            }.value
        }
        if let cached = await api.cachedMap(path, as: GeoFeatureCollection.self) {
            let shapes = await build(cached.value)
            if loadedMunic == munic { stationShapes = shapes; stationsLoadedFor = munic }
            if revalidated.contains(path) { return }
        }
        do {
            if case .updated(let fresh) = try await api.stationShapes(munic) {
                let shapes = await build(fresh)
                if loadedMunic == munic { stationShapes = shapes; stationsLoadedFor = munic }
            } else {
                stationsLoadedFor = munic
            }
            revalidated.insert(path)
        } catch {
            note(error, part: "voting district map")
        }
    }

    private func loadResults(_ munic: Int, api: ResultsAPI) async {
        loading.insert(.results)
        defer { loading.remove(.results) }
        if wards.isEmpty, let cached = await api.cached(await api.municDetailPath(munic), as: MunicDetail.self) {
            apply(cached.value, munic: munic)
        }
        do {
            switch try await api.municDetail(munic) {
            case .updated(let detail): apply(detail, munic: munic)
            case .unchanged: break
            }
            lastResults = Date()
        } catch ResultsError.awaitingResults {
            lastResults = Date()        // no ward results published for this council yet
        } catch {
            note(error, part: "ward results")
        }
    }

    private func apply(_ detail: MunicDetail, munic: Int) {
        guard loadedMunic == munic else { return }
        wards = Dictionary(detail.wards.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        detailAsOf = detail.reportDate
        Memory.relieveSoon()      // return the parse buffers (up to ~17 MB raw for Johannesburg)
    }

    private func loadLeaders(api: ResultsAPI) async {
        loading.insert(.leaders)
        defer { loading.remove(.leaders) }
        if leaders.isEmpty, let cached = await api.cached(await api.wardLeadersPath, as: WardLeaders.self), active {
            leaders = cached.value.byWard
        }
        do {
            if case .updated(let fresh) = try await api.wardLeaders(), active { leaders = fresh.byWard }
            lastLeaders = Date()
        } catch {
            note(error, part: "ward leaders")
        }
    }

    private func loadStationNames(api: ResultsAPI) async {
        loading.insert(.names)
        defer { loading.remove(.names) }
        let path = api.stationNamesPath
        let index: @Sendable ([StationName]) async -> [Int: String] = { list in
            await Task.detached(priority: .utility) {
                var out: [Int: String] = [:]
                out.reserveCapacity(list.count)
                for s in list { if let id = Int(s.vdnumber) { out[id] = s.name.stationTitleCase } }
                return out
            }.value
        }
        if let cached = await api.cachedMap(path, as: [StationName].self) {
            let names = await index(cached.value)
            if active { stationNames = names }   // the dashboard may have closed meanwhile: keep nothing
            return                       // names don't change during a count: never refetched once cached
        }
        do {
            if case .updated(let list) = try await api.stationNames() {
                let names = await index(list)
                if active { stationNames = names }
            }
        } catch {
            note(error, part: "station names")
        }
    }

    private func note(_ error: Error, part: String) {
        if error is CancellationError { return }
        let offline = (error as? ResultsError)?.isConnectivity ?? false
        let haveData = !wardShapes.isEmpty || !wards.isEmpty
        if offline {
            problem = haveData ? "Offline — showing saved ward data" : "Offline — wards load once you’re back online"
        } else {
            problem = haveData ? "Couldn’t refresh \(part) — showing saved data" : "Couldn’t load \(part)"
        }
    }
}
