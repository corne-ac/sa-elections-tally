import Foundation

// MARK: - IEC results file schema
//
// The IEC results dashboard (results.elections.org.za/dashboards/lge) has no documented API.
// It renders static JSON files that the IEC rewrites throughout the count:
//
//   MapsJason/2026/EEID1887LiteMapsNational.js   national + province + municipality summaries (~270 KB)
//   MapsJason/2026/EEID1887Province{1-9}.js      one province with its full party list (~110 KB each)
//   MapsJason/2021/EEID1091LiteMapsNational.js   final 2021 results (swing baseline)
//   MapsJason/2026/PartyList.js                  party abbreviations and colours
//
// Decoding is deliberately lenient: every field is optional on the wire and defaults to zero,
// so a renamed or missing field degrades one number rather than the whole dashboard.

/// Count progress and council status. The same block appears at national, province and municipality level.
struct CountProgress: Decodable, Sendable, Equatable {
    var municExpected = 0, wardsExpected = 0, vdsExpected = 0, seatsExpected = 0
    var municComplete = 0, wardsComplete = 0, vdsComplete = 0, seatsComplete = 0
    var percMunic = 0.0, percWards = 0.0, percVDs = 0.0, percSeats = 0.0
    var hungCouncils = 0, drawnCouncils = 0, majorityCouncils = 0
    var registeredVoters = 0

    /// Councils whose seat calculation has not been done yet (the IEC's "Not yet calculated").
    var councilsPending: Int { max(0, municExpected - municComplete) }
    var isComplete: Bool { vdsExpected > 0 && vdsComplete >= vdsExpected }

    enum Keys: String, CodingKey {
        case MunicExpected, WardExpected, VDExpected, SeatsExpected
        case MuncipalitiesComplete, WardsComplete, VDsComplete, SeatsComplete   // sic: "Muncipalities"
        case Perc_MunicipalityComplete, Perc_WardsComplete, Perc_VDsComplete, Perc_SeatsComplete
        case HungCouncils, DeadLockDrawnCouncils, MajorityCouncils, RegPop
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        municExpected = c.int(.MunicExpected)
        wardsExpected = c.int(.WardExpected)
        vdsExpected = c.int(.VDExpected)
        seatsExpected = c.int(.SeatsExpected)
        municComplete = c.int(.MuncipalitiesComplete)
        wardsComplete = c.int(.WardsComplete)
        vdsComplete = c.int(.VDsComplete)
        seatsComplete = c.int(.SeatsComplete)
        percMunic = c.double(.Perc_MunicipalityComplete)
        percWards = c.double(.Perc_WardsComplete)
        percVDs = c.double(.Perc_VDsComplete)
        percSeats = c.double(.Perc_SeatsComplete)
        hungCouncils = c.int(.HungCouncils)
        drawnCouncils = c.int(.DeadLockDrawnCouncils)
        majorityCouncils = c.int(.MajorityCouncils)
        registeredVoters = c.int(.RegPop)
    }
}

struct PartyResult: Decodable, Sendable, Identifiable, Equatable {
    let id: Int
    let name: String
    let votes: Int
    let percent: Double
    let wardSeats: Int
    let prSeats: Int
    let totalSeats: Int
    let availableSeats: Int
    let councilsWon: Int
    let majorityWon: Int
    /// Ward-ballot votes (the ballot that elects the ward councillor) and PR-ballot votes.
    let wardVotes: Int
    let prVotes: Int
    /// Ward councillor candidate. The IEC fills this in for the winner and uses "-" otherwise.
    let candidate: String?
    // Ballot totals for the area (repeated on every party row by the IEC)
    let ballotsCast: Int
    let validVotes: Int
    let spoiltVotes: Int
    let specialVotes: Int

    /// IEC id for the aggregated "OTHER" bucket. Never treated as a leader.
    static let otherID = -2
    /// IEC id for independent candidates.
    static let independentsID = 0

    var isAggregate: Bool { id == Self.otherID }

    enum Keys: String, CodingKey {
        case ID, Name, TotalValidVotes, PercOfVotes, WardSeatsWon, PRSeatsWon, TotalSeatsWon, AvailableSeats
        case CouncilsWon, MajorityWon, TotalVotesCast, ValidVotesCast, SpoiltVotes, SpecialVotes
        case WardVotes, PRVotes, CandidateName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(Int.self, forKey: .ID)
        name = (try? c.decodeIfPresent(String.self, forKey: .Name)) ?? ""
        votes = c.int(.TotalValidVotes)
        percent = c.double(.PercOfVotes)
        wardSeats = c.int(.WardSeatsWon)
        prSeats = c.int(.PRSeatsWon)
        totalSeats = c.int(.TotalSeatsWon)
        availableSeats = c.int(.AvailableSeats)
        councilsWon = c.int(.CouncilsWon)
        majorityWon = c.int(.MajorityWon)
        wardVotes = c.int(.WardVotes)
        prVotes = c.int(.PRVotes)
        let name = (try? c.decodeIfPresent(String.self, forKey: .CandidateName))?.trimmingCharacters(in: .whitespaces)
        candidate = (name == nil || name == "-" || name == "") ? nil : name
        ballotsCast = c.int(.TotalVotesCast)
        validVotes = c.int(.ValidVotesCast)
        spoiltVotes = c.int(.SpoiltVotes)
        specialVotes = c.int(.SpecialVotes)
    }
}

struct MunicipalityResult: Decodable, Sendable, Identifiable, Equatable {
    let id: Int
    let provinceID: Int
    /// Raw IEC label, e.g. "JHB - City of Johannesburg" or "EC105 - Ndlambe".
    let label: String
    let parties: [PartyResult]
    let progress: CountProgress

    var code: String { label.components(separatedBy: " - ").first ?? label }
    var displayName: String {
        let parts = label.components(separatedBy: " - ")
        let name = parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : label
        return name.replacingOccurrences(of: "City of ", with: "")
    }

    enum Keys: String, CodingKey { case MunicipalityID, ProvinceID, Municipality, PartyBallotResults }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(Int.self, forKey: .MunicipalityID)
        provinceID = c.int(.ProvinceID)
        label = (try? c.decodeIfPresent(String.self, forKey: .Municipality)) ?? "Municipality \(id)"
        parties = (try? c.decodeIfPresent([PartyResult].self, forKey: .PartyBallotResults)) ?? []
        progress = (try? CountProgress(from: decoder)) ?? CountProgress()
        // WardResults is intentionally not decoded: it is empty in the national file and large elsewhere.
    }
}

struct ProvinceResult: Decodable, Sendable, Identifiable, Equatable {
    let id: Int
    let name: String
    let parties: [PartyResult]
    let municipalities: [MunicipalityResult]
    let progress: CountProgress
    let reportDate: Date?

    enum Keys: String, CodingKey { case ProvinceID, Province, PartyBallotResults, MunicipalityResults, ReportDate }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(Int.self, forKey: .ProvinceID)
        name = (try? c.decodeIfPresent(String.self, forKey: .Province)) ?? Province.name(for: id)
        parties = (try? c.decodeIfPresent([PartyResult].self, forKey: .PartyBallotResults)) ?? []
        municipalities = (try? c.decodeIfPresent([MunicipalityResult].self, forKey: .MunicipalityResults)) ?? []
        progress = (try? CountProgress(from: decoder)) ?? CountProgress()
        reportDate = IECDate.parse(try? c.decodeIfPresent(String.self, forKey: .ReportDate))
    }
}

struct NationalResult: Decodable, Sendable, Equatable {
    let reportDate: Date?
    let parties: [PartyResult]
    let provinces: [ProvinceResult]
    let progress: CountProgress

    enum Keys: String, CodingKey { case ReportDate, PartyBallotResults, ProvinceResults }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        reportDate = IECDate.parse(try? c.decodeIfPresent(String.self, forKey: .ReportDate))
        parties = (try? c.decodeIfPresent([PartyResult].self, forKey: .PartyBallotResults)) ?? []
        provinces = (try? c.decodeIfPresent([ProvinceResult].self, forKey: .ProvinceResults)) ?? []
        progress = (try? CountProgress(from: decoder)) ?? CountProgress()
    }
}

// MARK: - Ward and voting-district level (EEID…Munic{id}.js)
//
// The IEC leaves the progress fields at zero below municipality level, so "counted" is inferred:
// a voting district counts as captured once it reports any votes.

struct MunicDetail: Decodable, Sendable {
    let id: Int
    let reportDate: Date?
    let wards: [WardDetail]

    enum Keys: String, CodingKey { case MunicipalityID, ReportDate, WardResults }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = c.int(.MunicipalityID)
        reportDate = IECDate.parse(try? c.decodeIfPresent(String.self, forKey: .ReportDate))
        wards = (try? c.decodeIfPresent([WardDetail].self, forKey: .WardResults)) ?? []
    }
}

struct WardDetail: Decodable, Sendable, Identifiable {
    let id: Int                     // e.g. 79800023 = Johannesburg ward 23
    let parties: [PartyResult]      // only parties with votes
    let stations: [StationDetail]

    var number: Int { id % 1000 }
    var countedStations: Int { stations.filter(\.isCounted).count }
    var countedFraction: Double { stations.isEmpty ? 0 : Double(countedStations) / Double(stations.count) }
    var wardBallotTotal: Int { parties.reduce(0) { $0 + $1.wardVotes } }
    var totalVotes: Int { parties.reduce(0) { $0 + $1.votes } }
    /// Parties ranked on the ward ballot, which decides the councillor.
    var wardRanking: [PartyResult] { parties.filter { $0.wardVotes > 0 }.sorted { $0.wardVotes > $1.wardVotes } }
    /// Set once the IEC declares the ward: the party holding the ward seat and its candidate.
    var councillor: PartyResult? { parties.first { $0.wardSeats > 0 } }

    enum Keys: String, CodingKey { case WardID, PartyBallotResults, VotingDistrictResults }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = c.int(.WardID)
        parties = ((try? c.decodeIfPresent([PartyResult].self, forKey: .PartyBallotResults)) ?? []).filter { $0.votes > 0 }
        stations = (try? c.decodeIfPresent([StationDetail].self, forKey: .VotingDistrictResults)) ?? []
    }
}

struct StationDetail: Decodable, Sendable, Identifiable {
    let id: Int                     // voting district number, e.g. 32860728
    let parties: [PartyResult]      // combined ward + PR votes; only parties with votes

    var isCounted: Bool { !parties.isEmpty }
    var totalVotes: Int { parties.reduce(0) { $0 + $1.votes } }
    var ranked: [PartyResult] { parties.sorted { $0.votes > $1.votes } }

    enum Keys: String, CodingKey { case VotingDistrictID, PartyBallotResults }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = c.int(.VotingDistrictID)
        parties = ((try? c.decodeIfPresent([PartyResult].self, forKey: .PartyBallotResults)) ?? []).filter { $0.votes > 0 }
    }
}

/// Lite ward leaders from EEID…BigMapsNational.js: the leading party and share for every ward with
/// results nationwide (the IEC nests them under the first municipality of each province).
struct WardLeaders: Decodable, Sendable {
    struct Leader: Sendable { let party: Int; let percent: Double }
    let byWard: [Int: Leader]

    private struct File: Decodable { let ProvinceResults: [P]? }
    private struct P: Decodable { let MunicipalityResults: [M]? }
    private struct M: Decodable { let WardResults: [W]? }
    private struct W: Decodable { let WardID: Int; let PartyBallotResults: [L]? }
    private struct L: Decodable { let ID: Int; let PercOfVotes: Double? }

    init(from decoder: Decoder) throws {
        let file = try File(from: decoder)
        var out: [Int: Leader] = [:]
        for p in file.ProvinceResults ?? [] {
            for m in p.MunicipalityResults ?? [] {
                for w in m.WardResults ?? [] {
                    if let lead = w.PartyBallotResults?.first, (lead.PercOfVotes ?? 0) > 0 {
                        out[w.WardID] = Leader(party: lead.ID, percent: lead.PercOfVotes ?? 0)
                    }
                }
            }
        }
        byWard = out
    }
}

/// Entry in ElectionMap/MapData/vs.js (voting station names by voting district number).
struct StationName: Decodable, Sendable {
    let vdnumber: String
    let name: String
}

// MARK: - GeoJSON (on-demand ward and voting-district boundaries)

struct GeoFeatureCollection: Decodable, Sendable {
    let features: [GeoFeature]
}

struct GeoFeature: Decodable, Sendable {
    struct Properties: Decodable, Sendable {
        let wardID: Int?        // PklWardID (ward files) or WardId (voting-district files)
        let wardNumber: Int?
        let vdNumber: Int?

        enum Keys: String, CodingKey { case PklWardID, WardId, WardNo, VDNumber }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            func lenient(_ k: Keys) -> Int? {
                if let v = try? c.decodeIfPresent(Int.self, forKey: k) { return v }
                if let v = try? c.decodeIfPresent(Double.self, forKey: k) { return Int(v) }
                if let s = try? c.decodeIfPresent(String.self, forKey: k) { return Int(s) }
                return nil
            }
            wardID = lenient(.PklWardID) ?? lenient(.WardId)
            wardNumber = lenient(.WardNo)
            vdNumber = lenient(.VDNumber)
        }
    }

    struct Geometry: Decodable, Sendable {
        /// Outer rings only, as [lon, lat] pairs.
        let rings: [[[Double]]]
        enum Keys: String, CodingKey { case type, coordinates }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            switch (try? c.decode(String.self, forKey: .type)) ?? "" {
            case "Polygon":
                rings = ((try? c.decode([[[Double]]].self, forKey: .coordinates)) ?? []).prefix(1).map { $0 }
            case "MultiPolygon":
                rings = ((try? c.decode([[[[Double]]]].self, forKey: .coordinates)) ?? []).compactMap(\.first)
            default:
                rings = []
            }
        }
    }

    let properties: Properties
    let geometry: Geometry?
}

/// Entry in MapsJason/{year}/PartyList.js
struct PartyListEntry: Decodable, Sendable {
    let ID: Int
    let Name: String?
    let PartyFullName: String?
    let sWebColour: String?
}

// MARK: - Helpers

enum Province {
    static let codes: [Int: String] = [1: "EC", 2: "FS", 3: "GP", 4: "KZN", 5: "MP", 6: "NC", 7: "LP", 8: "NW", 9: "WC"]
    static let names: [Int: String] = [
        1: "Eastern Cape", 2: "Free State", 3: "Gauteng", 4: "KwaZulu-Natal", 5: "Mpumalanga",
        6: "Northern Cape", 7: "Limpopo", 8: "North West", 9: "Western Cape",
    ]
    static func code(for id: Int) -> String { codes[id] ?? "P\(id)" }
    static func name(for id: Int) -> String { names[id] ?? "Province \(id)" }
}

enum Metro {
    /// The eight metropolitan councils (ids are stable across IEC election years).
    static let ids: [Int] = [3003, 9006, 4005, 3004, 3002, 1001, 1117, 2207]
}

enum IECDate {
    /// IEC timestamps carry 7 fractional digits ("2026-11-05T15:59:49.6905392+02:00"),
    /// which ISO8601DateFormatter rejects, so the fraction is trimmed to milliseconds first.
    static func parse(_ raw: String?) -> Date? {
        guard var s = raw, !s.isEmpty else { return nil }
        if let dot = s.firstIndex(of: ".") {
            let afterDot = s.index(after: dot)
            let tzStart = s[afterDot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) ?? s.endIndex
            let fraction = String(s[afterDot..<tzStart].prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            s = String(s[..<dot]) + "." + fraction + String(s[tzStart...])
        }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}

extension KeyedDecodingContainer {
    func int(_ key: Key) -> Int {
        if let v = try? decodeIfPresent(Int.self, forKey: key) { return v }
        if let v = try? decodeIfPresent(Double.self, forKey: key) { return Int(v) }
        return 0
    }
    func double(_ key: Key) -> Double {
        (try? decodeIfPresent(Double.self, forKey: key)) ?? 0
    }
}
