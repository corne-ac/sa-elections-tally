import AppKit
import SwiftUI

/// Abbreviations, display names and colours for parties.
///
/// Priority: a small curated table for the big parties (stable IEC ids, readable colours in
/// light and dark mode) → the IEC's own PartyList.js → initials derived from the ballot name.
struct PartyCatalog: Sendable {
    private struct Entry: Sendable { let abbr: String?; let fullName: String?; let hex: String? }
    private var entries: [Int: Entry] = [:]

    private static let curated: [Int: (abbr: String, name: String, hex: String)] = [
        7: ("ANC", "African National Congress", "#1FA34A"),
        52: ("DA", "Democratic Alliance", "#1F6FD6"),
        945: ("EFF", "Economic Freedom Fighters", "#D7263D"),
        1748: ("MK", "uMkhonto weSizwe Party", "#D63AA8"),
        3: ("IFP", "Inkatha Freedom Party", "#F08A24"),
        957: ("PA", "Patriotic Alliance", "#13A3A3"),
        1511: ("ActionSA", "ActionSA", "#7B5CD6"),
        4: ("VF+", "Freedom Front Plus", "#E5A50A"),
        445: ("SACP", "South African Communist Party", "#B83232"),
        PartyResult.independentsID: ("IND", "Independent candidates", "#8E9AAF"),
        PartyResult.otherID: ("Other", "All other parties", "#9AA0A6"),
    ]

    private static let curatedByAbbr: [String: String] = [
        "ATM": "#8D6E4F", "ACDP": "#3D5A80", "UDM": "#E0B000", "GOOD": "#F26B38",
        "BOSA": "#00897B", "RISE": "#EC6A9C", "AL JAMA-AH": "#2E7D32", "COPE": "#C2A14D",
    ]

    /// IEC uses this pale blue as a "no colour assigned" placeholder.
    private static let placeholderHex = "#BAE5F2"

    private static let fallbackPalette = [
        "#5E81AC", "#BF616A", "#A3BE8C", "#B48EAD", "#D08770", "#88C0D0", "#EBCB8B", "#8FBCBB", "#C678DD", "#56B6C2",
    ]

    init() {}

    init(partyList: [PartyListEntry]) {
        for p in partyList {
            entries[p.ID] = Entry(abbr: p.Name?.trimmingCharacters(in: .whitespaces),
                                  fullName: p.PartyFullName,
                                  hex: p.sWebColour)
        }
    }

    func abbr(_ id: Int, ballotName: String = "") -> String {
        if let c = Self.curated[id] { return c.abbr }
        if let a = entries[id]?.abbr, !a.isEmpty { return Self.prettyAbbr(a) }
        return Self.initials(of: ballotName.isEmpty ? (entries[id]?.fullName ?? "?") : ballotName)
    }

    func fullName(_ id: Int, ballotName: String = "") -> String {
        if let c = Self.curated[id] { return c.name }
        let raw = !ballotName.isEmpty ? ballotName : (entries[id]?.fullName ?? abbr(id))
        return Self.titleCase(raw)
    }

    func hex(_ id: Int, ballotName: String = "") -> String {
        if let c = Self.curated[id] { return c.hex }
        let a = abbr(id, ballotName: ballotName).uppercased()
        if let h = Self.curatedByAbbr[a] { return h }
        if let h = entries[id]?.hex, h.uppercased() != Self.placeholderHex, h.hasPrefix("#"), Self.isReadable(h) { return h }
        return Self.fallbackPalette[abs(id) % Self.fallbackPalette.count]
    }

    func color(_ id: Int, ballotName: String = "") -> Color { Color(hex: hex(id, ballotName: ballotName)) }
    func nsColor(_ id: Int, ballotName: String = "") -> NSColor { NSColor(hex: hex(id, ballotName: ballotName)) }

    /// Rejects near-white (and near-black) IEC colours that vanish on light or dark backgrounds.
    private static func isReadable(_ hex: String) -> Bool {
        guard let c = NSColor(hex: hex).usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.12 && luminance < 0.82
    }

    // MARK: Text helpers

    private static func prettyAbbr(_ a: String) -> String {
        switch a.uppercased() {
        case "ACTIONSA": return "ActionSA"
        case "VF PLUS": return "VF+"
        case "MKP": return "MK"
        case "RISE MZANSI": return "RISE"
        default: return a
        }
    }

    private static let smallWords: Set<String> = ["OF", "THE", "AND", "FOR", "IN", "VAN", "DIE", "EN", "|", "-", "&"]

    static func initials(of name: String) -> String {
        let words = name.uppercased().split(whereSeparator: { $0 == " " || $0 == "/" })
            .map(String.init).filter { !smallWords.contains($0) }
        let s = words.compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : String(s.prefix(6))
    }

    static func titleCase(_ raw: String) -> String {
        let keepUpper: Set<String> = ["SA", "RSA", "ANC", "DA", "EFF", "IFP", "UDM", "ACDP", "ATM", "PAC", "AIC", "NFP", "SACP"]
        let lowerWords: Set<String> = ["of", "the", "and", "for", "in", "van", "die", "en"]
        return raw.split(separator: " ", omittingEmptySubsequences: true).enumerated().map { idx, word in
            let w = String(word)
            if keepUpper.contains(w.uppercased()) { return w.uppercased() }
            let lower = w.lowercased()
            if idx > 0 && lowerWords.contains(lower) { return lower }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }
}

// MARK: - Hex colours

extension Color {
    init(hex: String) { self.init(nsColor: NSColor(hex: hex)) }
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        let r = CGFloat((v >> 16) & 0xFF) / 255, g = CGFloat((v >> 8) & 0xFF) / 255, b = CGFloat(v & 0xFF) / 255
        self.init(srgbRed: r, green: g, blue: b, alpha: 1)
    }
}
