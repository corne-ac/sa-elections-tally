import Foundation

enum ResultsError: LocalizedError, Equatable {
    case awaitingResults
    case offline
    case http(Int)
    case badData
    case network(String)

    var errorDescription: String? {
        switch self {
        case .awaitingResults: return "Awaiting results capture"
        case .offline: return "No internet connection"
        case .http(let code): return "IEC server returned HTTP \(code)"
        case .badData: return "Unexpected data from the IEC (maybe a captive portal or maintenance page)"
        case .network(let message): return message
        }
    }

    var isConnectivity: Bool {
        switch self {
        case .offline, .network: return true
        default: return false
        }
    }
}

/// Result of a conditional fetch.
enum Fetched<T: Sendable>: Sendable {
    case updated(T)
    case unchanged      // HTTP 304: the IEC has not rewritten the file since our copy
}

/// Talks to the IEC's public results files. Runs off the main actor.
///
/// Built to be light on the network and on the IEC:
/// - responses arrive gzip-compressed (~30 KB for the 270 KB national file);
/// - every repeat request is conditional (If-None-Match / If-Modified-Since), so an unchanged
///   file costs a 304 with no body and no JSON decoding;
/// - an ephemeral URLSession means no HTTP cache or cookies in ~/Library. The only thing on disk is
///   Tally's own small offline cache (DiskCache), which uninstall removes.
actor ResultsAPI {
    static let dashboardURL = URL(string: "https://results.elections.org.za/dashboards/lge/")!
    /// Dev/test override (e.g. a dead port to simulate an outage). Unset in normal use.
    private static let filesBase = URL(string: ProcessInfo.processInfo.environment["TALLY_BASE_URL"]
                                       ?? "https://results.elections.org.za/dashboards/lge/MapsJason/")!
    /// Boundary files used by the IEC's own map (ward and voting-district outlines, station names).
    private static let mapBase = URL(string: ProcessInfo.processInfo.environment["TALLY_MAP_BASE_URL"]
                                     ?? "https://results.elections.org.za/ElectionMap/MapData/")!

    let year = 2026
    let baselineYear = 2021
    /// Electoral event ids as published on the dashboard page; re-read from the page at launch.
    private(set) var eventID = 1887
    private(set) var baselineEventID = 1091
    private var discovery: Task<Void, Never>?
    private var discovered = false
    private var lastDiscoveryAttempt = Date.distantPast

    private var validators: [String: DiskCache.Validators] = [:]
    private let session: URLSession
    private let decoder = JSONDecoder()
    nonisolated let meter = NetworkMeter()
    nonisolated let cache = DiskCache()

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = false          // fail fast; the store decides when to retry
        config.httpMaximumConnectionsPerHost = 4
        config.httpAdditionalHeaders = [
            "User-Agent": "Tally/1.1 (macOS menu bar results viewer)",
            "Accept": "application/json, text/javascript, */*",
            "Accept-Encoding": "gzip, deflate, br",
        ]
        session = URLSession(configuration: config, delegate: meter, delegateQueue: nil)
    }

    // MARK: Paths

    var nationalPath: String { "\(year)/EEID\(eventID)LiteMapsNational.js" }
    func provincePath(_ id: Int) -> String { "\(year)/EEID\(eventID)Province\(id).js" }
    var baselinePath: String { "\(baselineYear)/EEID\(baselineEventID)LiteMapsNational.js" }
    let partyListPath = "2026/PartyList.js"

    // MARK: Endpoints

    func national() async throws -> Fetched<NationalResult> {
        await discoverEventIDs()
        return try await load(nationalPath, as: NationalResult.self, validate: { !$0.parties.isEmpty })
    }

    func province(_ id: Int) async throws -> Fetched<ProvinceResult> {
        await discoverEventIDs()
        return try await load(provincePath(id), as: ProvinceResult.self, validate: { $0.id == id })
    }

    func baseline() async throws -> Fetched<NationalResult> {
        await discoverEventIDs()
        return try await load(baselinePath, as: NationalResult.self, validate: { !$0.parties.isEmpty })
    }

    func partyList() async throws -> Fetched<[PartyListEntry]> {
        try await load(partyListPath, as: [PartyListEntry].self, validate: { !$0.isEmpty })
    }

    // MARK: Drill-down endpoints (fetched only when you open a municipality or ward)

    var wardLeadersPath: String { "\(year)/EEID\(eventID)BigMapsNational.js" }
    func municDetailPath(_ id: Int) -> String { "\(year)/EEID\(eventID)Munic\(id).js" }
    func wardShapesPath(_ municID: Int) -> String { "\(year)/municward\(municID).js" }
    func stationShapesPath(_ municID: Int) -> String { "\(year)/municvd\(municID).js" }
    let stationNamesPath = "vs.js"

    /// Ward leaders nationwide (~37 KB gzip).
    func wardLeaders() async throws -> Fetched<WardLeaders> {
        await discoverEventIDs()
        return try await load(wardLeadersPath, as: WardLeaders.self, validate: { _ in true })
    }

    /// Full ward and voting-district results for one municipality (90–480 KB gzip). Zero-vote rows are
    /// stripped before decoding and before caching (Johannesburg: 17.5 MB → 2.7 MB).
    func municDetail(_ id: Int) async throws -> Fetched<MunicDetail> {
        await discoverEventIDs()
        return try await load(municDetailPath(id), as: MunicDetail.self,
                              transform: ZeroVoteFilter.strip, validate: { !$0.wards.isEmpty })
    }

    func wardShapes(_ municID: Int) async throws -> Fetched<GeoFeatureCollection> {
        try await load(wardShapesPath(municID), base: Self.mapBase, as: GeoFeatureCollection.self,
                       validate: { !$0.features.isEmpty })
    }

    func stationShapes(_ municID: Int) async throws -> Fetched<GeoFeatureCollection> {
        try await load(stationShapesPath(municID), base: Self.mapBase, as: GeoFeatureCollection.self,
                       validate: { !$0.features.isEmpty })
    }

    /// Voting station names for the whole country (~240 KB gzip, once; they don't change during a count).
    func stationNames() async throws -> Fetched<[StationName]> {
        try await load(stationNamesPath, base: Self.mapBase, as: [StationName].self,
                       transform: Self.stripBOM, validate: { !$0.isEmpty })
    }

    func cachedMap<T: Decodable & Sendable>(_ path: String, as type: T.Type) -> (value: T, savedAt: Date)? {
        cached(Self.cacheKey(path, base: Self.mapBase), as: type)
    }

    /// vs.js starts with a UTF-8 byte-order mark.
    private static func stripBOM(_ data: Data) -> Data {
        data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
    }

    private static func cacheKey(_ path: String, base: URL) -> String {
        base == mapBase ? "map/" + path : path
    }

    // MARK: Offline cache

    /// Loads a file from the offline cache. Also primes its validators so the next network
    /// request can come back as a cheap 304.
    func cached<T: Decodable & Sendable>(_ path: String, as type: T.Type) -> (value: T, savedAt: Date)? {
        guard let entry = cache.read(path),
              let value = try? decoder.decode(T.self, from: entry.data) else { return nil }
        validators[path] = entry.validators
        return (value, entry.savedAt)
    }

    func cachedNational() async -> (value: NationalResult, savedAt: Date)? {
        cached(nationalPath, as: NationalResult.self)
    }

    // MARK: Plumbing

    private func load<T: Decodable & Sendable>(_ path: String, base: URL = filesBase, as type: T.Type,
                                               transform: ((Data) -> Data)? = nil,
                                               validate: (T) -> Bool) async throws -> Fetched<T> {
        let key = Self.cacheKey(path, base: base)
        var request = URLRequest(url: base.appendingPathComponent(path))
        if let v = validators[key] {
            if let etag = v.etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let modified = v.lastModified { request.setValue(modified, forHTTPHeaderField: "If-Modified-Since") }
        }

        let (data, http) = try await send(request)
        switch http.statusCode {
        case 304:
            meter.countUnchanged()
            return .unchanged
        case 200..<300:
            // A captive portal or Cloudflare challenge returns HTML with a 200: decoding fails and the
            // caller keeps its last good data.
            let body = transform?(data) ?? data
            guard let value = try? decoder.decode(T.self, from: body), validate(value) else {
                meter.countFailure()
                throw ResultsError.badData
            }
            let v = DiskCache.Validators(etag: http.value(forHTTPHeaderField: "ETag"),
                                         lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
            validators[key] = v
            cache.write(key, data: body, validators: v)
            return .updated(value)
        case 404:
            throw ResultsError.awaitingResults
        default:
            meter.countFailure()
            throw ResultsError.http(http.statusCode)
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ResultsError.badData }
            return (data, http)
        } catch let error as ResultsError {
            throw error
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            meter.countFailure()
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                throw ResultsError.offline
            default:
                throw ResultsError.network(error.localizedDescription)
            }
        } catch {
            meter.countFailure()
            throw ResultsError.network(error.localizedDescription)
        }
    }

    /// Reads `var EEID2026 = "EEID1887"` (and the 2021 id) from the dashboard page. One attempt per launch,
    /// retried at most every 10 minutes if it failed. Concurrent callers share the in-flight attempt.
    private func discoverEventIDs() async {
        if discovered { return }
        if discovery == nil {
            guard Date().timeIntervalSince(lastDiscoveryAttempt) > 600 else { return }
            lastDiscoveryAttempt = Date()
            discovery = Task { [weak self] in await self?.performDiscovery() }
        }
        await discovery?.value
        discovery = nil
    }

    private func performDiscovery() async {
        var request = URLRequest(url: Self.dashboardURL)
        request.timeoutInterval = 8
        guard let (data, http) = try? await send(request), http.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else { return }
        if let id = Self.match(#"EEID\#(year)\s*=\s*"EEID(\d+)""#, in: html) { eventID = id }
        if let id = Self.match(#"EEID\#(baselineYear)\s*=\s*"EEID(\d+)""#, in: html) { baselineEventID = id }
        discovered = true
    }

    private static func match(_ pattern: String, in text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }
}

// MARK: - Network meter (feeds the resource monitor)

/// Counts real bytes on the wire (compressed bodies + headers) from URLSession task metrics.
final class NetworkMeter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    struct Stats: Sendable, Equatable {
        var bytes: Int64 = 0
        var requests = 0
        var unchanged = 0
        var failures = 0
        var lastLatency: TimeInterval = 0
    }

    private let lock = NSLock()
    private var stats = Stats()

    var snapshot: Stats { lock.withLock { stats } }

    func countUnchanged() { lock.withLock { stats.unchanged += 1 } }
    func countFailure() { lock.withLock { stats.failures += 1 } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let bytes = metrics.transactionMetrics.reduce(Int64(0)) {
            $0 + $1.countOfResponseBodyBytesReceived + $1.countOfResponseHeaderBytesReceived
                + $1.countOfRequestHeaderBytesSent + $1.countOfRequestBodyBytesSent
        }
        lock.withLock {
            stats.bytes += bytes
            stats.requests += 1
            stats.lastLatency = metrics.taskInterval.duration
        }
    }
}

// MARK: - Offline cache

/// Last good copy of each IEC file, so Tally starts instantly and keeps working offline.
/// Lives in ~/Library/Caches/local.tally.sa-elections, removed by uninstall.
/// Files are LZFSE-compressed (the core set is ~250 KB on disk). Drill-down files (municipality
/// results and boundaries) are evicted oldest-first once the cache passes 25 MB.
/// Every operation is best-effort: a cache failure never affects the live data path.
final class DiskCache: Sendable {
    struct Validators: Codable, Sendable { var etag: String?; var lastModified: String? }
    private struct Meta: Codable { var validators: Validators; var savedAt: Date; var compressed: Bool? }

    private static let limit: Int64 = 25 * 1_048_576
    private static let target: Int64 = 15 * 1_048_576

    let directory: URL?

    init() {
        if let override = ProcessInfo.processInfo.environment["TALLY_CACHE_DIR"] {
            directory = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            directory = caches?.appendingPathComponent(Bundle.main.bundleIdentifier ?? "local.tally.sa-elections", isDirectory: true)
        }
    }

    private func file(_ path: String) -> URL? {
        directory?.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
    }

    func read(_ path: String) -> (data: Data, validators: Validators, savedAt: Date)? {
        guard let url = file(path),
              let stored = try? Data(contentsOf: url),
              let metaData = try? Data(contentsOf: url.appendingPathExtension("meta")),
              let meta = try? JSONDecoder().decode(Meta.self, from: metaData) else { return nil }
        let data: Data
        if meta.compressed == true {
            guard let raw = try? (stored as NSData).decompressed(using: .lzfse) as Data else { return nil }
            data = raw
        } else {
            data = stored
        }
        // Mark as recently used so eviction keeps what you actually look at.
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return (data, meta.validators, meta.savedAt)
    }

    func write(_ path: String, data: Data, validators: Validators) {
        guard let dir = directory, let url = file(path) else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let packed = try? (data as NSData).compressed(using: .lzfse) as Data
        guard (try? (packed ?? data).write(to: url, options: .atomic)) != nil else { return }
        if let meta = try? JSONEncoder().encode(Meta(validators: validators, savedAt: Date(), compressed: packed != nil)) {
            try? meta.write(to: url.appendingPathExtension("meta"), options: .atomic)
        }
        evictIfNeeded()
    }

    /// Removes the least recently used drill-down files once the cache passes its limit.
    private func evictIfNeeded() {
        guard let dir = directory, sizeOnDisk > Self.limit,
              let files = try? FileManager.default.contentsOfDirectory(
                  at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        let evictable = files
            .filter { $0.pathExtension != "meta" }
            .filter { let n = $0.lastPathComponent; return n.contains("Munic") || n.hasPrefix("map_2026_munic") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
        var size = sizeOnDisk
        for url in evictable where size > Self.target {
            let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("meta"))
            size -= bytes
        }
    }

    var sizeOnDisk: Int64 {
        guard let dir = directory,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
