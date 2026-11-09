import Foundation

/// Where the map is: South Africa → province → municipality → ward (whose voting stations are shown).
enum MapLevel: Equatable, Sendable {
    case national
    case province(Int)
    case municipality(Int)
    case ward(munic: Int, ward: Int)
}

/// Everything under the pointer, from the finest layer to the coarsest.
struct MapHit: Equatable, Sendable {
    var detail: Int?       // ward (municipality level) or voting district (ward level)
    var context: Int?      // neighbouring ward (ward level)
    var munic: Int?
    var province: Int?
}

enum MapAction: Equatable, Sendable {
    case select(Int?)
    case openProvince(Int)
    case openMunicipality(Int)
    case openWard(Int)
    case goUp
    case none
}

/// The map's click rules, kept free of UI so they can be tested on their own.
///
/// One rule at every level: **click** selects the thing at this level (shows its details);
/// **double-click** opens it one level deeper; double-clicking a neighbour moves sideways to it;
/// double-clicking empty space goes back up.
enum MapNavigation {
    /// The unit you interact with at each level.
    static func target(_ level: MapLevel, _ hit: MapHit, parentOf: (Int) -> Int?) -> Int? {
        switch level {
        case .national: return hit.province
        case .province(let p): return hit.munic.flatMap { parentOf($0) == p ? $0 : nil }
        case .municipality, .ward: return hit.detail
        }
    }

    static func action(_ level: MapLevel, _ hit: MapHit, double: Bool, selected: Int?,
                       parentOf: (Int) -> Int?) -> MapAction {
        guard double else {
            let t = target(level, hit, parentOf: parentOf)
            return .select(t == selected ? nil : t)
        }
        switch level {
        case .national:
            if let p = hit.province { return .openProvince(p) }
            return .none
        case .province(let p):
            if let m = hit.munic, parentOf(m) == p { return .openMunicipality(m) }
            if let other = hit.province, other != p { return .openProvince(other) }
            return .goUp
        case .municipality(let m):
            if let w = hit.detail { return .openWard(w) }
            if let other = hit.munic, other != m { return .openMunicipality(other) }
            return .goUp
        case .ward(let m, let w):
            if let s = hit.detail { return .select(s) }                   // deepest level: select the station
            if let c = hit.context, c != w { return .openWard(c) }
            if let other = hit.munic, other != m { return .openMunicipality(other) }
            return .goUp
        }
    }
}
