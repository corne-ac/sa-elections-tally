import AppKit
import SwiftUI

// MARK: - Geometry (bundled, loaded once on first use)

/// South Africa's 213 municipalities and 9 provinces, pre-projected (Albers) and simplified by
/// scripts/build-map.py from the IEC's own 2026 boundary files. Bundled, so the national map never
/// needs the network. Ward and voting-district outlines are projected into the same grid on demand.
final class SAMap: @unchecked Sendable {
    let size: CGSize
    let grid: AlbersGrid
    /// Largest first: drawing in this order keeps municipalities that sit inside others visible,
    /// and hit-testing in reverse finds the innermost one.
    let munics: [GeoShape]
    let provinces: [GeoShape]
    let codes: [Int: String]
    var fullRect: CGRect { CGRect(origin: .zero, size: size) }

    /// nil when the resource is missing or unreadable; the map tab then says so instead of failing.
    static let shared: SAMap? = load()

    private init(size: CGSize, grid: AlbersGrid, munics: [GeoShape], provinces: [GeoShape], codes: [Int: String]) {
        self.size = size
        self.grid = grid
        self.munics = munics
        self.provinces = provinces
        self.codes = codes
    }

    private struct Raw: Decodable {
        struct Feature: Decodable { let i: Int; let p: Int?; let c: String?; let r: [[Int]] }
        let w: Double, h: Double, m: [Feature], p: [Feature], proj: AlbersGrid
    }

    private static func load() -> SAMap? {
        guard let url = Bundle.main.url(forResource: "sa-map", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        func shape(_ f: Raw.Feature, parent: Int) -> GeoShape {
            let path = Self.path(f.r)
            return GeoShape(id: f.i, parent: parent, number: 0, path: path, bounds: path.boundingRect)
        }
        let munics = raw.m.map { shape($0, parent: $0.p ?? 0) }
            .sorted { $0.bounds.width * $0.bounds.height > $1.bounds.width * $1.bounds.height }
        let provinces = raw.p.map { shape($0, parent: $0.i) }
        let codes = Dictionary(raw.m.map { ($0.i, $0.c ?? "") }, uniquingKeysWith: { a, _ in a })
        return SAMap(size: CGSize(width: raw.w, height: raw.h), grid: raw.proj, munics: munics, provinces: provinces, codes: codes)
    }

    /// Rings are delta-encoded integer pairs.
    private static func path(_ rings: [[Int]]) -> Path {
        var path = Path()
        for ring in rings where ring.count >= 6 {
            var x = 0, y = 0
            for i in stride(from: 0, to: ring.count - 1, by: 2) {
                x += ring[i]; y += ring[i + 1]
                let p = CGPoint(x: x, y: y)
                if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.closeSubpath()
        }
        return path
    }

    func bounds(ofProvince id: Int) -> CGRect? { provinces.first { $0.id == id }?.bounds }
    func munic(_ id: Int) -> GeoShape? { munics.first { $0.id == id } }
}

// MARK: - Map tab

/// One rule at every level: **click** shows details, **double-click** zooms in one level,
/// **double-click outside** (or Esc, or ‹) goes back up.
/// South Africa → province → municipality → ward → voting station.
struct MapTab: View {
    let store: ElectionStore

    enum ColourBy: String, CaseIterable { case councils = "Councils", provinces = "Provinces" }

    @State private var colourBy: ColourBy = .councils
    @State private var visible: CGRect?                // nil = whole country
    @State private var hovered: Int?
    @State private var selected: Int?
    @FocusState private var focused: Bool

    private var drill: DrillDown { store.drill }

    var body: some View {
        if let map = SAMap.shared {
            VStack(alignment: .leading, spacing: 8) {
                header(map)
                ZStack(alignment: .bottomLeading) {
                    MapCanvas(map: map, scene: scene(map), rect: visible ?? map.fullRect,
                              onHover: { hovered = target($0, map: map) },
                              onClick: { clicked($0, double: $1, map: map) },
                              onPan: { visible = $0 })
                    statusChip
                }
                .frame(height: 230)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.025)))

                InfoRow(store: store, map: map, focus: hovered ?? selected,
                        canOpen: hovered == nil && selected != nil,
                        open: { if let id = selected { open(id, map: map) } })

                switch drill.level {
                case .national:
                    Legend(store: store, map: map, province: nil, provinceMode: colourBy == .provinces)
                case .province(let p):
                    Legend(store: store, map: map, province: p, provinceMode: colourBy == .provinces)
                case .municipality:
                    WardGrid(store: store, highlight: hovered ?? selected,
                             onHover: { hovered = $0 },
                             onOpen: { drill.openWard($0) })
                case .ward(_, let ward):
                    WardPanel(store: store, wardID: ward, highlight: hovered ?? selected,
                              onHover: { hovered = $0 }, onSelect: { selected = $0 })
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onKeyPress(.escape) {
                guard drill.level != .national else { return .ignored }   // at the top, Esc closes the window
                drill.goUp()
                return .handled
            }
            .onAppear {
                refit(map, animated: false)
                focused = true
            }
            .onChange(of: drill.level) { _, _ in
                hovered = nil
                selected = nil
                refit(map)
            }
            .onChange(of: drill.wardShapes.count) { _, _ in
                if drill.wardID != nil { refit(map) }
            }
        } else {
            VStack(spacing: 6) {
                Image(systemName: "map").font(.system(size: 26)).foregroundStyle(.secondary)
                Text("Map data unavailable").font(.headline)
                Text("sa-map.json is missing from the app bundle. Rebuild with scripts/build.sh.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    // MARK: Header: back + breadcrumbs, colour toggle while looking at councils

    @ViewBuilder
    private func header(_ map: SAMap) -> some View {
        HStack(spacing: 6) {
            if drill.level != .national {
                Button { drill.goUp() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold)).frame(width: 16, height: 18)
                }
                .buttonStyle(.borderless)
                .help("Back (Esc)")
            }
            Breadcrumbs(store: store, map: map)
            Spacer(minLength: 0)
            if drill.municID == nil {
                Picker("", selection: $colourBy) {
                    ForEach(ColourBy.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
                .help("Colour by the leader of each council, or of each province")
            }
        }
        .frame(height: 20)
    }

    @ViewBuilder
    private var statusChip: some View {
        if drill.needsDetail {
            if drill.isLoading {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(drill.loading.contains(.stations) || drill.loading.contains(.names) ? "Loading voting stations…"
                         : drill.loading.contains(.wards) ? "Loading wards…" : "Updating…")
                }
                .font(.system(size: 9.5, weight: .medium))
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Capsule().fill(.regularMaterial))
                .padding(6)
            } else if let problem = drill.problem {
                Label(problem, systemImage: "wifi.exclamationmark")
                    .font(.system(size: 9.5, weight: .medium))
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(Capsule().fill(.regularMaterial))
                    .padding(6)
            }
        }
    }

    // MARK: Interaction

    /// What the pointer is over, at the current level's unit.
    private func target(_ hit: MapHit, map: SAMap) -> Int? {
        MapNavigation.target(drill.level, hit, parentOf: { map.munic($0)?.parent })
    }

    private func clicked(_ hit: MapHit, double: Bool, map: SAMap) {
        switch MapNavigation.action(drill.level, hit, double: double, selected: selected,
                                    parentOf: { map.munic($0)?.parent }) {
        case .select(let id): selected = id
        case .openProvince(let p): drill.openProvince(p)
        case .openMunicipality(let m): drill.openMunicipality(m)
        case .openWard(let w): drill.openWard(w)
        case .goUp: drill.goUp()
        case .none: break
        }
    }

    /// The "Zoom in ›" style button on the info row.
    private func open(_ id: Int, map: SAMap) {
        switch drill.level {
        case .national: drill.openProvince(id)
        case .province: drill.openMunicipality(id)
        case .municipality: drill.openWard(id)
        case .ward: selected = id
        }
    }

    private func refit(_ map: SAMap, animated: Bool = true) {
        let target: CGRect?
        switch drill.level {
        case .national: target = nil
        case .province(let p): target = map.bounds(ofProvince: p)?.padded(0.04)
        case .municipality(let m): target = map.munic(m)?.bounds.padded(0.08)
        case .ward(let m, let w): target = (drill.wardShape(w)?.bounds ?? map.munic(m)?.bounds)?.padded(0.18)
        }
        if animated {
            withAnimation(.smooth(duration: 0.6)) { visible = target }
        } else {
            visible = target
        }
    }

    // MARK: Scene

    private func scene(_ map: SAMap) -> MapScene {
        let catalog = store.catalog
        var scene = MapScene()
        let focusID = hovered ?? selected

        func partyColour(_ parties: [PartyResult], progress: CountProgress) -> Color? {
            guard progress.vdsComplete > 0,
                  let lead = store.ranked(parties).first(where: { !$0.isAggregate && $0.percent > 0 }) else { return nil }
            return catalog.color(lead.id, ballotName: lead.name).opacity(0.38 + 0.62 * min(1, max(0, progress.percVDs / 100)))
        }
        func councilFills() {
            if colourBy == .provinces {
                scene.provinceMode = true
                var byProvince: [Int: Color] = [:]
                for p in store.provinces { byProvince[p.id] = partyColour(p.parties, progress: p.progress) }
                for m in map.munics { scene.baseFills[m.id] = byProvince[m.parent] }
            } else {
                for (id, m) in store.municipalities { scene.baseFills[id] = partyColour(m.parties, progress: m.progress) }
            }
        }

        switch drill.level {
        case .national:
            councilFills()
            scene.highlight = focusID.flatMap { id in map.provinces.first { $0.id == id }?.path }
        case .province(let p):
            councilFills()
            scene.focusProvince = p
            scene.focus = map.provinces.first { $0.id == p }?.path
            scene.highlight = focusID.flatMap { map.munic($0)?.path }
        case .municipality(let munic):
            scene.dimBase = true
            scene.detail = drill.wardShapes
            scene.detailFills = wardFills()
            scene.focus = map.munic(munic)?.path
            scene.highlight = focusID.flatMap { id in drill.wardShapes.first { $0.id == id }?.path }
            if drill.wardShapes.isEmpty, let m = store.municipalities[munic] {
                scene.baseFills[munic] = partyColour(m.parties, progress: m.progress)   // until wards arrive
            }
        case .ward(_, let ward):
            scene.dimBase = true
            scene.context = drill.wardShapes.filter { $0.id != ward }
            scene.contextFills = wardFills().mapValues { $0.opacity(0.35) }
            scene.detail = drill.stationShapesInWard
            scene.detailFills = stationFills(ward)
            scene.focus = drill.wardShape(ward)?.path
            scene.highlight = focusID.flatMap { id in scene.detail.first { $0.id == id }?.path }
        }
        return scene
    }

    private func wardFills() -> [Int: Color] {
        let catalog = store.catalog
        var out: [Int: Color] = [:]
        for shape in drill.wardShapes {
            if let w = drill.ward(shape.id), let lead = w.wardRanking.first ?? w.parties.max(by: { $0.votes < $1.votes }) {
                out[shape.id] = catalog.color(lead.id, ballotName: lead.name).opacity(0.38 + 0.62 * w.countedFraction)
            } else if let l = drill.leaders[shape.id] {
                out[shape.id] = catalog.color(l.party).opacity(0.75)
            }
        }
        return out
    }

    private func stationFills(_ ward: Int) -> [Int: Color] {
        let catalog = store.catalog
        var out: [Int: Color] = [:]
        for s in drill.ward(ward)?.stations ?? [] {
            if let lead = s.ranked.first { out[s.id] = catalog.color(lead.id, ballotName: lead.name).opacity(0.9) }
        }
        return out
    }
}

private extension CGRect {
    func padded(_ fraction: CGFloat) -> CGRect {
        insetBy(dx: -max(width, height) * fraction, dy: -max(width, height) * fraction)
    }
}

// MARK: - Scene description

struct MapScene {
    var baseFills: [Int: Color] = [:]
    var provinceMode = false
    var dimBase = false
    /// At province level: municipalities outside this province are drawn faded.
    var focusProvince: Int?
    var context: [GeoShape] = []
    var contextFills: [Int: Color] = [:]
    var detail: [GeoShape] = []
    var detailFills: [Int: Color] = [:]
    var focus: Path?
    var highlight: Path?
}

// MARK: - Canvas (animatable, so zooms glide)

struct MapCanvas: View, Animatable {
    let map: SAMap
    let scene: MapScene
    var rect: CGRect
    let onHover: (MapHit) -> Void
    let onClick: (MapHit, Bool) -> Void         // hit, isDoubleClick
    let onPan: (CGRect) -> Void

    @State private var gestureStart: CGRect?

    nonisolated var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(AnimatablePair(rect.origin.x, rect.origin.y), AnimatablePair(rect.width, rect.height)) }
        set { rect = CGRect(x: newValue.first.first, y: newValue.first.second, width: newValue.second.first, height: newValue.second.second) }
    }

    var body: some View {
        GeometryReader { geo in
            let t = Self.transform(rect: rect, in: geo.size)
            let scale = t.a
            Canvas { ctx, size in
                ctx.concatenate(t)
                let visibleRect = CGRect(origin: .zero, size: size).applying(t.inverted())
                let neutral = Color.primary.opacity(0.07)
                let seam = Color(nsColor: .windowBackgroundColor).opacity(0.75)

                for m in map.munics where m.bounds.intersects(visibleRect) {
                    var fill = scene.baseFills[m.id] ?? (scene.dimBase ? Color.primary.opacity(0.05) : neutral)
                    if let p = scene.focusProvince, m.parent != p { fill = fill.opacity(0.3) }
                    ctx.fill(m.path, with: .color(fill))
                    if !scene.provinceMode { ctx.stroke(m.path, with: .color(seam), lineWidth: 0.45 / scale) }
                }
                for p in map.provinces where p.bounds.intersects(visibleRect) {
                    ctx.stroke(p.path, with: .color(.primary.opacity(scene.dimBase ? 0.25 : (scene.provinceMode ? 0.55 : 0.4))),
                               lineWidth: 0.9 / scale)
                }
                for c in scene.context where c.bounds.intersects(visibleRect) {
                    ctx.fill(c.path, with: .color(scene.contextFills[c.id] ?? Color.primary.opacity(0.06)))
                    ctx.stroke(c.path, with: .color(seam), lineWidth: 0.6 / scale)
                }
                for d in scene.detail where d.bounds.intersects(visibleRect) {
                    ctx.fill(d.path, with: .color(scene.detailFills[d.id] ?? Color.primary.opacity(0.10)))
                    ctx.stroke(d.path, with: .color(seam), lineWidth: 0.7 / scale)
                }
                if let focus = scene.focus {
                    ctx.stroke(focus, with: .color(.primary.opacity(0.75)), lineWidth: 1.4 / scale)
                }
                if let shape = scene.highlight {
                    ctx.stroke(shape, with: .color(Color(nsColor: .windowBackgroundColor)), lineWidth: 3.2 / scale)
                    ctx.stroke(shape, with: .color(.primary), lineWidth: 1.6 / scale)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): onHover(hit(point, t))
                case .ended: onHover(MapHit())
                }
            }
            .onTapGesture(coordinateSpace: .local) { point in
                // Each click arrives here; the second click of a double-click carries clickCount 2.
                onClick(hit(point, t), (NSApp.currentEvent?.clickCount ?? 1) >= 2)
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let start = gestureStart ?? rect
                        gestureStart = start
                        onPan(clamp(start.offsetBy(dx: -value.translation.width / scale, dy: -value.translation.height / scale)))
                    }
                    .onEnded { _ in gestureStart = nil }
            )
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = gestureStart ?? rect
                        gestureStart = start
                        let anchor = value.startLocation.applying(t.inverted())
                        let factor = 1 / max(0.2, value.magnification)
                        let w = start.width * factor, h = start.height * factor
                        let fx = (anchor.x - start.minX) / start.width, fy = (anchor.y - start.minY) / start.height
                        onPan(clamp(CGRect(x: anchor.x - w * fx, y: anchor.y - h * fy, width: w, height: h)))
                    }
                    .onEnded { _ in gestureStart = nil }
            )
        }
    }

    static func transform(rect: CGRect, in size: CGSize) -> CGAffineTransform {
        guard rect.width > 0, rect.height > 0, size.width > 0, size.height > 0 else { return .identity }
        let s = min(size.width / rect.width, size.height / rect.height)
        let tx = (size.width - rect.width * s) / 2 - rect.minX * s
        let ty = (size.height - rect.height * s) / 2 - rect.minY * s
        return CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: tx, ty: ty)
    }

    /// Zoom from the whole country down to a single voting district (~4000×), kept over the country.
    private func clamp(_ r: CGRect) -> CGRect {
        let full = map.fullRect
        let w = min(full.width, max(0.5, r.width))
        let h = w * (r.height / max(r.width, 0.0001))
        let cx = min(full.maxX, max(full.minX, r.midX)), cy = min(full.maxY, max(full.minY, r.midY))
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    private func hit(_ point: CGPoint, _ t: CGAffineTransform) -> MapHit {
        let p = point.applying(t.inverted())
        var hit = MapHit()
        hit.detail = scene.detail.reversed().first { $0.bounds.contains(p) && $0.path.contains(p) }?.id
        hit.context = scene.context.reversed().first { $0.bounds.contains(p) && $0.path.contains(p) }?.id
        if let m = map.munics.reversed().first(where: { $0.bounds.contains(p) && $0.path.contains(p) }) {
            hit.munic = m.id
            hit.province = m.parent
        } else {
            hit.province = map.provinces.first { $0.bounds.contains(p) && $0.path.contains(p) }?.id
        }
        return hit
    }
}

// MARK: - Breadcrumbs: South Africa ▾ › Gauteng › Johannesburg › Ward 23

private struct Breadcrumbs: View {
    let store: ElectionStore
    let map: SAMap

    var body: some View {
        let drill = store.drill
        HStack(spacing: 3) {
            Menu {
                Button("Whole country") { drill.goNational() }
                Divider()
                ForEach(1...9, id: \.self) { id in
                    Button(Province.name(for: id)) { drill.openProvince(id) }
                }
            } label: {
                Text("South Africa")
                    .font(.system(size: 11, weight: drill.level == .national ? .semibold : .regular))
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
            .font(.system(size: 11))
            .fixedSize()
            .help("Jump to a province")

            if let p = drill.provinceID {
                separator
                if case .province = drill.level {
                    Text(Province.name(for: p)).fontWeight(.semibold).lineLimit(1)
                } else {
                    crumb(Province.code(for: p)) { drill.openProvince(p) }
                        .help(Province.name(for: p))
                }
            }
            if let m = drill.municID {
                separator
                let name = store.municipalities[m]?.displayName ?? map.codes[m] ?? "Municipality"
                if drill.wardID != nil {
                    crumb(name) { drill.openMunicipality(m) }
                } else {
                    Text(name).fontWeight(.semibold).lineLimit(1)
                }
            }
            if let w = drill.wardID {
                separator
                Text("Ward \(drill.wardShape(w)?.number ?? w % 1000)").fontWeight(.semibold).lineLimit(1)
            }
        }
        .font(.system(size: 11))
    }

    private var separator: some View {
        Image(systemName: "chevron.compact.right").font(.system(size: 10)).foregroundStyle(.tertiary)
    }

    private func crumb(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.borderless).foregroundStyle(.secondary).lineLimit(1)
    }
}

// MARK: - Hover / selection details (one quiet row, no box)

private struct InfoRow: View {
    let store: ElectionStore
    let map: SAMap
    let focus: Int?
    let canOpen: Bool
    let open: () -> Void

    var body: some View {
        let drill = store.drill
        HStack(alignment: .center, spacing: 10) {
            if let id = focus {
                switch drill.level {
                case .national: provinceRow(id)
                case .province: municRow(id)
                case .municipality: wardRow(id)
                case .ward: stationRow(id)
                }
            } else {
                Text(hint).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2)
                Spacer(minLength: 0)
            }
        }
        .frame(minHeight: 32)
        .padding(.horizontal, 2)
    }

    private var hint: String {
        switch store.drill.level {
        case .national: return "Click a province for details · double-click to zoom in · pinch to zoom"
        case .province: return "Double-click a municipality to see its wards · double-click outside or Esc to go back"
        case .municipality: return "Double-click a ward to see its voting stations · fainter means fewer stations counted"
        case .ward: return "Hover a district or a station below · grey districts aren’t counted yet · Esc to go back"
        }
    }

    @ViewBuilder
    private func provinceRow(_ id: Int) -> some View {
        let p = store.province(id)
        VStack(alignment: .leading, spacing: 2) {
            title(Province.name(for: id), subtitle: Province.code(for: id))
            TopParties(store: store, parties: store.ranked(p?.parties ?? []).filter { !$0.isAggregate }, value: { $0.percent })
        }
        Spacer(minLength: 4)
        trailing(progress: p.map { "\(Fmt.num0($0.progress.percVDs))% counted" }, action: canOpen ? "Zoom in" : nil)
    }

    @ViewBuilder
    private func municRow(_ id: Int) -> some View {
        let m = store.municipalities[id]
        VStack(alignment: .leading, spacing: 2) {
            title(m?.displayName ?? map.codes[id] ?? "Municipality", subtitle: m?.code ?? map.codes[id] ?? "")
            TopParties(store: store, parties: store.ranked(m?.parties ?? []).filter { !$0.isAggregate }, value: { $0.percent })
        }
        Spacer(minLength: 4)
        trailing(progress: m.map { "\(Fmt.num0($0.progress.percVDs))% counted" }, action: canOpen ? "Wards" : nil)
    }

    @ViewBuilder
    private func wardRow(_ id: Int) -> some View {
        let drill = store.drill
        let w = drill.ward(id)
        let number = drill.wardShape(id)?.number ?? id % 1000
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text("Ward \(number)").font(.system(size: 12, weight: .semibold))
                if let c = w?.councillor, let name = c.candidate {
                    Label(name.stationTitleCase, systemImage: "checkmark.seal.fill")
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.controlled).lineLimit(1)
                }
            }
            if let w, w.wardBallotTotal > 0 {
                TopParties(store: store, parties: w.wardRanking, value: { Double($0.wardVotes) / Double(w.wardBallotTotal) * 100 })
            } else if let l = drill.leaders[id] {
                HStack(spacing: 3) {
                    PartyDot(color: store.catalog.color(l.party), size: 6)
                    Text("\(store.catalog.abbr(l.party)) leading · \(Fmt.num1(l.percent))%").font(.system(size: 10.5, design: .rounded))
                }
            } else {
                Text("No results captured yet").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        Spacer(minLength: 4)
        trailing(progress: w.map { "\($0.countedStations)/\($0.stations.count) stations" }, action: canOpen ? "Stations" : nil)
    }

    @ViewBuilder
    private func stationRow(_ id: Int) -> some View {
        let drill = store.drill
        let station = drill.wardID.flatMap { drill.ward($0) }?.stations.first { $0.id == id }
        VStack(alignment: .leading, spacing: 2) {
            title(drill.stationName(id), subtitle: drill.hasName(id) ? "VD \(id)" : "")
            if let s = station, s.isCounted {
                TopParties(store: store, parties: s.ranked, value: { Double($0.votes) / Double(max(s.totalVotes, 1)) * 100 })
            } else {
                Text("Not counted yet").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        Spacer(minLength: 4)
        trailing(progress: station.map { $0.isCounted ? "\(Fmt.grouped($0.totalVotes)) votes" : "Awaiting" }, action: nil)
    }

    private func title(_ text: String, subtitle: String) -> some View {
        HStack(spacing: 5) {
            Text(text).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            if !subtitle.isEmpty {
                Text(verbatim: subtitle).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func trailing(progress: String?, action: String?) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            if let progress { Text(progress).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary) }
            if let action {
                Button(action: open) {
                    HStack(spacing: 2) { Text(action); Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)) }
                }
                .buttonStyle(.borderless).controlSize(.small).font(.system(size: 10.5, weight: .semibold))
            }
        }
    }
}

private struct TopParties: View {
    let store: ElectionStore
    let parties: [PartyResult]
    let value: (PartyResult) -> Double

    var body: some View {
        let catalog = store.catalog
        let top = Array(parties.prefix(3))
        if top.isEmpty {
            Text("No results captured yet").font(.system(size: 10.5)).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                ForEach(top) { p in
                    HStack(spacing: 3) {
                        PartyDot(color: catalog.color(p.id, ballotName: p.name), size: 6)
                        Text(catalog.abbr(p.id, ballotName: p.name)).font(.system(size: 10.5, weight: .bold, design: .rounded))
                        Text(Fmt.num1(value(p))).font(.system(size: 10.5, design: .rounded)).monospacedDigit()
                    }
                }
            }
        }
    }
}

// MARK: - Legend (country or one province)

private struct Legend: View {
    let store: ElectionStore
    let map: SAMap
    let province: Int?
    let provinceMode: Bool

    var body: some View {
        let catalog = store.catalog
        let inScope: (Int) -> Bool = { id in province == nil || map.munic(id)?.parent == province }
        let leaders: [(PartyResult, Int)] = {
            var counts: [Int: (PartyResult, Int)] = [:]
            let areas: [(parties: [PartyResult], counted: Bool)] = provinceMode
                ? store.provinces.filter { province == nil || $0.id == province }.map { ($0.parties, $0.progress.vdsComplete > 0) }
                : store.municipalities.filter { inScope($0.key) }.map { ($0.value.parties, $0.value.progress.vdsComplete > 0) }
            for area in areas where area.counted {
                if let lead = store.ranked(area.parties).first(where: { !$0.isAggregate && $0.percent > 0 }) {
                    counts[lead.id] = (lead, (counts[lead.id]?.1 ?? 0) + 1)
                }
            }
            return counts.values.sorted { $0.1 > $1.1 }
        }()
        let total = provinceMode ? (province == nil ? 9 : 1) : map.munics.filter { inScope($0.id) }.count
        let pending = max(0, total - leaders.reduce(0) { $0 + $1.1 })

        HStack(spacing: 8) {
            Text(provinceMode ? "Leading" : "Councils led").font(.system(size: 9.5)).foregroundStyle(.tertiary)
            ForEach(leaders.prefix(4), id: \.0.id) { party, count in
                HStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2).fill(catalog.color(party.id, ballotName: party.name)).frame(width: 7, height: 7)
                    Text(catalog.abbr(party.id, ballotName: party.name)).font(.system(size: 10, weight: .semibold, design: .rounded))
                    Text("\(count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            let others = leaders.dropFirst(4).reduce(0) { $0 + $1.1 }
            if others > 0 {
                Text("+\(others)").font(.system(size: 10)).foregroundStyle(.secondary)
                    .help(leaders.dropFirst(4).map { "\(catalog.abbr($0.0.id, ballotName: $0.0.name)) \($0.1)" }.joined(separator: ", "))
            }
            if pending > 0 {
                Text("· \(pending) none yet").font(.system(size: 10)).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
    }
}

// MARK: - Municipality level: every ward as a tile

private struct WardGrid: View {
    let store: ElectionStore
    let highlight: Int?
    let onHover: (Int?) -> Void
    let onOpen: (Int) -> Void

    var body: some View {
        let drill = store.drill
        let catalog = store.catalog
        let tiles: [(id: Int, number: Int)] = drill.wardShapes.map { ($0.id, $0.number) }.sorted { $0.number < $1.number }
        let counted = drill.wards.values.reduce(0) { $0 + $1.countedStations }
        let stations = drill.wards.values.reduce(0) { $0 + $1.stations.count }
        let decided = drill.wards.values.filter { $0.councillor != nil }.count

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: "\(tiles.count) wards")
                Spacer()
                if stations > 0 {
                    Text("\(decided) decided · \(counted)/\(stations) stations counted")
                        .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 60), spacing: 4)], spacing: 4) {
                ForEach(tiles, id: \.id) { tile in
                    let (colour, abbr, fraction) = info(tile.id, catalog: catalog)
                    Button { onOpen(tile.id) } label: {
                        VStack(spacing: 0) {
                            Text("\(tile.number)").font(.system(size: 10.5, weight: .bold, design: .rounded)).monospacedDigit()
                            Text(abbr).font(.system(size: 8, weight: .semibold)).lineLimit(1).opacity(0.85)
                        }
                        .frame(maxWidth: .infinity, minHeight: 28)
                        .foregroundStyle(colour == nil ? Color.secondary : Color.primary)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill((colour ?? Color.primary).opacity(colour == nil ? 0.06 : 0.25 + 0.45 * fraction)))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(highlight == tile.id ? Color.primary : .clear, lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                    .onHover { inside in onHover(inside ? tile.id : nil) }
                    .help("Ward \(tile.number)")
                }
            }
        }
    }

    private func info(_ id: Int, catalog: PartyCatalog) -> (Color?, String, Double) {
        let drill = store.drill
        if let w = drill.ward(id), let lead = w.wardRanking.first ?? w.parties.max(by: { $0.votes < $1.votes }) {
            return (catalog.color(lead.id, ballotName: lead.name), catalog.abbr(lead.id, ballotName: lead.name), w.countedFraction)
        }
        if let l = drill.leaders[id] { return (catalog.color(l.party), catalog.abbr(l.party), 0.6) }
        return (nil, "—", 0)
    }
}

// MARK: - Ward level: summary and the tallied voting stations

private struct WardPanel: View {
    let store: ElectionStore
    let wardID: Int
    let highlight: Int?
    let onHover: (Int?) -> Void
    let onSelect: (Int) -> Void

    var body: some View {
        let drill = store.drill
        let catalog = store.catalog
        let ward = drill.ward(wardID)
        let stations = (ward?.stations ?? []).sorted { drill.stationName($0.id) < drill.stationName($1.id) }

        VStack(alignment: .leading, spacing: 10) {
            if let ward {
                Card(padding: 10) {
                    VStack(alignment: .leading, spacing: 7) {
                        if let c = ward.councillor {
                            HStack(spacing: 6) {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.controlled)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text("Councillor elected").font(.system(size: 9.5)).foregroundStyle(.secondary)
                                    Text("\(c.candidate?.stationTitleCase ?? "—") · \(catalog.abbr(c.id, ballotName: c.name))")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                            }
                        } else if let lead = ward.wardRanking.first, ward.wardBallotTotal > 0 {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.fill").foregroundStyle(.secondary)
                                Text("\(catalog.abbr(lead.id, ballotName: lead.name)) leads the ward ballot · \(ward.countedStations) of \(ward.stations.count) stations counted")
                                    .font(.system(size: 11, weight: .medium))
                            }
                        } else {
                            Text("No stations counted yet in this ward").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        }
                        let total = max(ward.wardBallotTotal, 1)
                        ForEach(ward.wardRanking.prefix(5)) { p in
                            let colour = catalog.color(p.id, ballotName: p.name)
                            HStack(spacing: 6) {
                                PartyDot(color: colour, size: 6)
                                Text(catalog.abbr(p.id, ballotName: p.name))
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .frame(width: 58, alignment: .leading).lineLimit(1)
                                ShareBar(fraction: Double(p.wardVotes) / Double(total), color: colour, height: 4)
                                Text(Fmt.pct(Double(p.wardVotes) / Double(total) * 100))
                                    .font(.system(size: 11, design: .rounded)).monospacedDigit()
                                    .frame(width: 46, alignment: .trailing)
                                Text(Fmt.grouped(p.wardVotes)).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                        if ward.wardBallotTotal > 0 {
                            Text("Ward ballot (elects the councillor) · \(Fmt.grouped(ward.wardBallotTotal)) valid votes")
                                .font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                }

                HStack {
                    SectionLabel(text: "Voting stations")
                    Spacer()
                    Text("\(ward.countedStations) of \(ward.stations.count) counted")
                        .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.secondary)
                }
                VStack(spacing: 4) {
                    ForEach(stations) { s in
                        StationRow(store: store, station: s, highlighted: highlight == s.id)
                            .onHover { inside in onHover(inside ? s.id : nil) }
                            .onTapGesture { onSelect(s.id) }
                    }
                }
            } else if store.drill.isLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Loading ward results…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                Text("No ward results published for this ward yet.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

private struct StationRow: View {
    let store: ElectionStore
    let station: StationDetail
    let highlighted: Bool

    var body: some View {
        let catalog = store.catalog
        let ranked = station.ranked
        let total = max(station.totalVotes, 1)
        HStack(spacing: 8) {
            Image(systemName: station.isCounted ? "checkmark.circle.fill" : "clock")
                .font(.system(size: 11))
                .foregroundStyle(station.isCounted ? Theme.controlled : Color.secondary)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(store.drill.stationName(station.id)).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    if store.drill.hasName(station.id) {
                        Text(verbatim: String(station.id)).font(.system(size: 9)).monospacedDigit().foregroundStyle(.tertiary)
                    }
                }
                if station.isCounted {
                    SplitBar(segments: segments(ranked, total: total, catalog: catalog), height: 4, spacing: 1)
                } else {
                    Text("Awaiting count").font(.system(size: 9.5)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if let lead = ranked.first {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 3) {
                        PartyDot(color: catalog.color(lead.id, ballotName: lead.name), size: 6)
                        Text(catalog.abbr(lead.id, ballotName: lead.name)).font(.system(size: 11, weight: .bold, design: .rounded))
                        Text(Fmt.num1(Double(lead.votes) / Double(total) * 100)).font(.system(size: 11, design: .rounded)).monospacedDigit()
                    }
                    Text("\(Fmt.grouped(station.totalVotes)) votes").font(.system(size: 9)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(highlighted ? 0.09 : 0.035)))
        .contentShape(Rectangle())
    }

    private func segments(_ ranked: [PartyResult], total: Int, catalog: PartyCatalog) -> [SplitBar.Segment] {
        var out = ranked.prefix(4).map {
            SplitBar.Segment(id: $0.id, value: Double($0.votes) / Double(total) * 100,
                             color: catalog.color($0.id, ballotName: $0.name), label: catalog.abbr($0.id, ballotName: $0.name))
        }
        let rest = ranked.dropFirst(4).reduce(0) { $0 + $1.votes }
        if rest > 0 {
            out.append(SplitBar.Segment(id: Int.min, value: Double(rest) / Double(total) * 100, color: .gray.opacity(0.5), label: "Other"))
        }
        return out
    }
}
