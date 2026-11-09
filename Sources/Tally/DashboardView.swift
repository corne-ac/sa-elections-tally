import SwiftUI

struct DashboardView: View {
    let store: ElectionStore
    let monitor: ResourceMonitor
    var onQuit: () -> Void
    var onUninstall: () -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case parties = "Parties", map = "Map", provinces = "Provinces", metros = "Metros", councils = "Councils"
        var id: String { rawValue }
    }

    @State private var tab: Tab
    @State private var showResources = false
    @AppStorage(Prefs.showMonitor) private var showMonitor = true

    init(store: ElectionStore, monitor: ResourceMonitor, onQuit: @escaping () -> Void,
         onUninstall: @escaping () -> Void, initialTab: Tab = .parties) {
        self.store = store
        self.monitor = monitor
        self.onQuit = onQuit
        self.onUninstall = onUninstall
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(spacing: 11) {
            HeaderView(store: store)

            if store.isShowingStaleData { StaleBanner(store: store) }

            if let national = store.national {
                HeroCard(store: store, progress: national.progress)
                CountCard(store: store, progress: national.progress)

                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ScrollView(.vertical) {
                    Group {
                        switch tab {
                        case .parties: PartiesTab(store: store)
                        case .map: MapTab(store: store)
                        case .provinces: ProvincesTab(store: store)
                        case .metros: MetrosTab(store: store, onOpen: { id in
                            store.drill.openMunicipality(id)
                            tab = .map
                        })
                        case .councils: CouncilsTab(store: store)
                        }
                    }
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.automatic)
                .frame(height: 316)
            } else {
                PlaceholderCard(store: store)
            }

            if showMonitor && showResources {
                ResourcePanel(monitor: monitor, store: store)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            FooterView(store: store, monitor: monitor, showResources: $showResources,
                       onQuit: onQuit, onUninstall: onUninstall)
        }
        .padding(.horizontal, 15)
        .padding(.top, 14)
        .padding(.bottom, 11)
        .frame(width: 400)
        // Solid backing: the popover's glass otherwise takes on whatever is behind it (a bright web page turns it
        // mid-grey), which drowns small coloured text such as swings and links. Seen on a real screen, not in renders.
        .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        .animation(.snappy, value: tab)
        .onChange(of: tab) { _, t in store.lastTab = t.rawValue }
        .onChange(of: store.requestedTab) { _, name in
            if let name, let t = Tab.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) { tab = t }
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    let store: ElectionStore
    @State private var spin = 0.0

    var body: some View {
        HStack(spacing: 10) {
            AppMark(size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Municipal Elections 2026").font(.system(size: 13.5, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            LiveBadge(state: store.state, isFinal: store.national?.progress.isComplete ?? false)
            Button {
                withAnimation(.easeInOut(duration: 0.8)) { spin += 360 }
                store.refreshNow()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .rotationEffect(.degrees(spin))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(store.isRefreshing)
            .help("Refresh now")
        }
    }

    private var subtitle: String {
        guard let date = store.dataAsOf else { return "South Africa · IEC results" }
        return "IEC report \(date.formatted(date: .omitted, time: .shortened)) · \(date.formatted(.relative(presentation: .named)))"
    }
}

// MARK: - Hero (leader, key numbers and count progress in one card)

private struct HeroCard: View {
    let store: ElectionStore
    let progress: CountProgress

    var body: some View {
        let catalog = store.catalog
        if let leader = store.leader {
            let color = catalog.color(leader.id, ballotName: leader.name)
            Card(padding: 13, tint: color) {
                VStack(alignment: .leading, spacing: 11) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Leading nationally").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            Text(catalog.abbr(leader.id, ballotName: leader.name))
                                .font(.system(size: 30, weight: .heavy, design: .rounded))
                                .foregroundStyle(color)
                                .shadow(color: color.opacity(0.3), radius: 7)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Text(catalog.fullName(leader.id, ballotName: leader.name))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        VStack(alignment: .trailing, spacing: 1) {
                            if let move = store.movement(leader.id), abs(move) >= 0.01 {
                                Text(Fmt.signed(move, digits: 2) + " since last update")
                                    .font(.system(size: 9.5, weight: .medium))
                                    .foregroundStyle(move >= 0 ? Theme.controlled : Theme.saRed)
                            } else {
                                Text("Vote share").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            }
                            Text(Fmt.pct(leader.percent, digits: 2))
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .contentTransition(.numericText(value: leader.percent))
                            Text("\(Fmt.compact(leader.votes)) votes")
                                .font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 0) {
                        if let second = store.runnerUp, let margin = store.margin {
                            MiniStat(title: "Lead",
                                     value: "+" + Fmt.num1(margin),
                                     detail: "over " + catalog.abbr(second.id, ballotName: second.name))
                        }
                        MiniStat(title: "vs 2021",
                                 value: store.swing(leader.id).map { Fmt.signed($0) } ?? "—",
                                 detail: store.baseline[leader.id].map { "was " + Fmt.pct($0) } ?? "",
                                 valueColor: store.swing(leader.id).map { $0 >= 0 ? Theme.controlled : Theme.saRed })
                        MiniStat(title: "Seats", value: Fmt.grouped(leader.totalSeats),
                                 detail: "of \(Fmt.grouped(leader.availableSeats))")
                        MiniStat(title: "Councils", value: Fmt.grouped(leader.councilsWon),
                                 detail: "\(leader.majorityWon) majority")
                    }

                }
            }
        }
    }
}

private struct MiniStat: View {
    let title: String
    let value: String
    let detail: String
    var valueColor: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 9.5)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor ?? .primary)
                .contentTransition(.numericText())
            Text(detail).font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Count progress (its own card: the overall count first, then wards, councils and seats)

private struct CountCard: View {
    let store: ElectionStore
    let progress: CountProgress

    var body: some View {
        let done = progress.vdsComplete, total = progress.vdsExpected
        let remaining = max(0, total - done)
        Card(padding: 12) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(progress.isComplete ? "Count complete" : "Count progress")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Voting districts counted").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(Fmt.num0(progress.percVDs) + "%")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(progress.isComplete ? Theme.controlled : .blue)
                        .contentTransition(.numericText(value: progress.percVDs))
                }

                ProgressBar(fraction: progress.percVDs / 100, tint: progress.isComplete ? Theme.controlled : .blue, height: 9)

                HStack(spacing: 6) {
                    Text("\(Fmt.grouped(done)) of \(Fmt.grouped(total))")
                        .font(.system(size: 10.5, weight: .medium)).monospacedDigit()
                    if remaining > 0 {
                        Text("· \(Fmt.grouped(remaining)) to go").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if remaining > 0, let pace = store.countingPace {
                        let hours = Double(remaining) / pace
                        Text("≈ \(Fmt.grouped(Int(pace)))/h · ~\(Self.duration(hours)) left")
                            .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.tertiary)
                            .help("Tally’s own estimate from the counting pace it has seen over the last 90 minutes. Not an IEC figure.")
                    }
                }
                .lineLimit(1)

                HStack(alignment: .top, spacing: 12) {
                    Sub(title: "Wards", done: progress.wardsComplete, total: progress.wardsExpected, percent: progress.percWards, tint: .teal)
                    Sub(title: "Councils", done: progress.municComplete, total: progress.municExpected, percent: progress.percMunic, tint: .purple)
                    Sub(title: "Seats", done: progress.seatsComplete, total: progress.seatsExpected, percent: progress.percSeats, tint: .orange)
                }
                .padding(.top, 2)
            }
        }
    }

    static func duration(_ hours: Double) -> String {
        if hours < 1 { return "\(max(1, Int((hours * 60).rounded()))) min" }
        if hours < 10 { return Fmt.num1(hours) + " h" }
        return "\(Int(hours.rounded())) h"
    }

    /// One secondary measure: name and % on one line, a thin bar, then done / total.
    private struct Sub: View {
        let title: String
        let done: Int
        let total: Int
        let percent: Double
        let tint: Color

        var body: some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(Fmt.num0(percent) + "%").font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                ProgressBar(fraction: percent / 100, tint: tint, height: 4)
                Text("\(Fmt.grouped(done)) / \(Fmt.grouped(total))")
                    .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("\(title) complete: \(Fmt.grouped(done)) of \(Fmt.grouped(total))")
        }
    }
}

// MARK: - Parties tab

private struct PartiesTab: View {
    let store: ElectionStore

    var body: some View {
        let catalog = store.catalog
        let parties = store.rankedNational
        let maxShare = parties.map(\.percent).max() ?? 100

        VStack(alignment: .leading, spacing: 10) {
            SplitBar(segments: splitSegments(parties, catalog: catalog, keep: 7), height: 12)
                .padding(.top, 2)

            ForEach(parties) { p in
                let color = catalog.color(p.id, ballotName: p.name)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 7) {
                        PartyDot(color: color, size: 9)
                        Text(catalog.abbr(p.id, ballotName: p.name))
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                        let full = catalog.fullName(p.id, ballotName: p.name)
                        if full.caseInsensitiveCompare(catalog.abbr(p.id, ballotName: p.name)) != .orderedSame {
                            Text(full).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(Fmt.pct(p.percent, digits: 2))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .contentTransition(.numericText(value: p.percent))
                    }
                    ShareBar(fraction: p.percent / max(maxShare, 0.01), color: color)
                        .padding(.leading, 16)
                    HStack {
                        Text("\(Fmt.compact(p.votes)) votes · \(Fmt.grouped(p.totalSeats)) seats · \(p.councilsWon) councils")
                            .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        Spacer()
                        SwingLabel(swing: p.isAggregate ? nil : store.swing(p.id))
                    }
                    .padding(.leading, 16)
                }
                .padding(.vertical, 2)
            }
        }
    }
}

/// Top `keep` parties plus one grey bucket for everyone else (including the IEC's OTHER).
func splitSegments(_ parties: [PartyResult], catalog: PartyCatalog, keep: Int) -> [SplitBar.Segment] {
    let named = parties.filter { !$0.isAggregate }
    var segments = named.prefix(keep).map {
        SplitBar.Segment(id: $0.id, value: $0.percent, color: catalog.color($0.id, ballotName: $0.name),
                         label: catalog.abbr($0.id, ballotName: $0.name))
    }
    let rest = named.dropFirst(keep).reduce(0) { $0 + $1.percent }
        + parties.filter(\.isAggregate).reduce(0) { $0 + $1.percent }
    if rest > 0 {
        segments.append(.init(id: Int.min, value: rest, color: .gray.opacity(0.55), label: "Other"))
    }
    return segments
}

// MARK: - Provinces tab

private struct ProvincesTab: View {
    let store: ElectionStore
    @State private var expanded: Set<Int> = []

    var body: some View {
        let catalog = store.catalog
        VStack(spacing: 6) {
            ForEach(store.provinces) { province in
                let ranked = store.ranked(province.parties)
                let lead = ranked.first { !$0.isAggregate }
                let isOpen = expanded.contains(province.id)

                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(.snappy) {
                            if isOpen { expanded.remove(province.id) } else { expanded.insert(province.id) }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Text(Province.code(for: province.id))
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .frame(width: 32, height: 22)
                                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill((lead.map { catalog.color($0.id, ballotName: $0.name) } ?? .gray).opacity(0.22)))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(province.name).font(.system(size: 12, weight: .semibold))
                                SplitBar(segments: splitSegments(ranked, catalog: catalog, keep: 3), height: 4, spacing: 1)
                            }
                            Spacer(minLength: 6)
                            VStack(alignment: .trailing, spacing: 2) {
                                if let lead {
                                    HStack(spacing: 4) {
                                        PartyDot(color: catalog.color(lead.id, ballotName: lead.name), size: 7)
                                        Text(catalog.abbr(lead.id, ballotName: lead.name))
                                            .font(.system(size: 12, weight: .bold, design: .rounded))
                                        Text(Fmt.pct(lead.percent))
                                            .font(.system(size: 12, weight: .medium, design: .rounded)).monospacedDigit()
                                    }
                                }
                                Text("\(Fmt.num0(province.progress.percVDs))% counted")
                                    .font(.system(size: 9.5)).foregroundStyle(.secondary)
                            }
                            .frame(width: 112, alignment: .trailing)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(isOpen ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    if isOpen {
                        ProvinceDetail(store: store, province: province, ranked: ranked)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(isOpen ? 0.06 : 0.035)))
            }
        }
    }
}

private struct ProvinceDetail: View {
    let store: ElectionStore
    let province: ProvinceResult
    let ranked: [PartyResult]

    var body: some View {
        let catalog = store.catalog
        let maxShare = ranked.map(\.percent).max() ?? 100
        let p = province.progress
        VStack(alignment: .leading, spacing: 6) {
            ForEach(ranked.prefix(8)) { party in
                let color = catalog.color(party.id, ballotName: party.name)
                HStack(spacing: 6) {
                    PartyDot(color: color, size: 6)
                    Text(catalog.abbr(party.id, ballotName: party.name))
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .frame(width: 58, alignment: .leading)
                        .lineLimit(1)
                    ShareBar(fraction: party.percent / max(maxShare, 0.01), color: color, height: 4)
                    Text(Fmt.pct(party.percent, digits: 2))
                        .font(.system(size: 11, weight: .medium, design: .rounded)).monospacedDigit()
                        .frame(width: 52, alignment: .trailing)
                    SwingLabel(swing: party.isAggregate ? nil : store.provinceSwing(province.id, party: party), suffix: "")
                        .frame(width: 38, alignment: .trailing)
                }
            }
            if store.provinceDetail[province.id] == nil {
                Text("Top parties only — full list loads with the province file.")
                    .font(.system(size: 9.5)).foregroundStyle(.tertiary)
            }
            HStack(spacing: 10) {
                Label("\(p.majorityCouncils) controlled", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.controlled)
                Label("\(p.hungCouncils) hung", systemImage: "scale.3d").foregroundStyle(Theme.hung)
                Label("\(p.councilsPending) pending", systemImage: "clock").foregroundStyle(.secondary)
            }
            .font(.system(size: 10, weight: .medium))
            .labelStyle(TightLabel())
            .padding(.top, 2)
        }
        .padding(.leading, 42)
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon.font(.system(size: 9)); configuration.title }
    }
}

// MARK: - Metros tab

private struct MetrosTab: View {
    let store: ElectionStore
    let onOpen: (Int) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            ForEach(store.metros) { metro in
                Button { onOpen(metro.id) } label: { MetroCard(store: store, metro: metro) }
                    .buttonStyle(.plain)
                    .help("Open \(metro.displayName)’s wards on the map")
            }
        }
    }
}

private struct MetroCard: View {
    let store: ElectionStore
    let metro: MunicipalityResult

    var body: some View {
        let catalog = store.catalog
        let ranked = store.ranked(metro.parties)
        let lead = ranked.first { !$0.isAggregate }
        let status = Self.status(metro, lead: lead)
        let seats = lead?.availableSeats ?? metro.progress.seatsExpected
        let majority = seats > 0 ? seats / 2 + 1 : 0

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(metro.code).font(.system(size: 9.5, weight: .heavy, design: .rounded)).foregroundStyle(.secondary)
                Spacer()
                Chip(text: status.label, color: status.color)
            }
            Text(metro.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            if let lead {
                let color = catalog.color(lead.id, ballotName: lead.name)
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(catalog.abbr(lead.id, ballotName: lead.name))
                        .font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(color)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text(Fmt.pct(lead.percent))
                        .font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                }
            }
            SplitBar(segments: splitSegments(ranked, catalog: catalog, keep: 3), height: 5, spacing: 1)
            Text(ranked.filter { !$0.isAggregate }.dropFirst().prefix(2)
                    .map { "\(catalog.abbr($0.id, ballotName: $0.name)) \(Fmt.num1($0.percent))" }
                    .joined(separator: " · "))
                .font(.system(size: 9.5)).foregroundStyle(.secondary).lineLimit(1)
            Divider().opacity(0.5)
            HStack {
                Text("\(Fmt.num0(metro.progress.percVDs))% counted")
                Spacer()
                if majority > 0 { Text("\(majority) for majority") }
            }
            .font(.system(size: 9.5)).monospacedDigit().foregroundStyle(.secondary)
            HStack(spacing: 3) {
                Image(systemName: "map").font(.system(size: 8.5))
                Text("Wards & stations")
                Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.tint)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.75))
    }

    /// Mirrors the IEC's "key councils" status logic.
    static func status(_ m: MunicipalityResult, lead: PartyResult?) -> (label: String, color: Color) {
        if m.progress.seatsComplete < m.progress.seatsExpected { return ("Counting", .blue) }
        if let lead, lead.majorityWon > 0 { return ("Majority", Theme.controlled) }
        if m.progress.drawnCouncils > 0 { return ("Drawn", Theme.drawn) }
        return ("Hung", Theme.hung)
    }
}

// MARK: - Councils tab

private struct CouncilsTab: View {
    let store: ElectionStore

    var body: some View {
        let catalog = store.catalog
        let p = store.national?.progress ?? CountProgress()
        let winners = store.rankedNational.filter { $0.councilsWon > 0 && !$0.isAggregate }
            .sorted { $0.councilsWon > $1.councilsWon }

        VStack(alignment: .leading, spacing: 10) {
            Card(padding: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        SectionLabel(text: "Council control")
                        Spacer()
                        Text("\(p.municExpected) councils").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    SplitBar(segments: [
                        .init(id: 1, value: Double(p.majorityCouncils), color: Theme.controlled, label: "Controlled"),
                        .init(id: 2, value: Double(p.hungCouncils), color: Theme.hung, label: "Hung"),
                        .init(id: 3, value: Double(p.drawnCouncils), color: Theme.drawn, label: "Drawn"),
                        .init(id: 4, value: Double(p.councilsPending), color: .gray.opacity(0.35), label: "Pending"),
                    ].filter { $0.value > 0 }, height: 10)
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        GridRow {
                            LegendItem(color: Theme.controlled, label: "Controlled", value: p.majorityCouncils)
                            LegendItem(color: Theme.hung, label: "Hung (<50%)", value: p.hungCouncils)
                        }
                        GridRow {
                            LegendItem(color: Theme.drawn, label: "Drawn (=50%)", value: p.drawnCouncils)
                            LegendItem(color: .gray.opacity(0.5), label: "Not yet calculated", value: p.councilsPending)
                        }
                    }
                }
            }

            if !winners.isEmpty {
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            SectionLabel(text: "Councils won by party")
                            Spacer()
                            HStack(spacing: 8) {
                                LegendSwatch(opacity: 0.35, label: "Leading")
                                LegendSwatch(opacity: 1, label: "Majority")
                            }
                        }
                        let most = max(winners.map(\.councilsWon).max() ?? 1, 1)
                        VStack(spacing: 7) {
                            ForEach(winners) { party in
                                let color = catalog.color(party.id, ballotName: party.name)
                                HStack(spacing: 8) {
                                    Text(catalog.abbr(party.id, ballotName: party.name))
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .frame(width: 58, alignment: .leading)
                                        .lineLimit(1)
                                    GeometryReader { geo in
                                        let w = geo.size.width
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.primary.opacity(0.06))
                                            Capsule().fill(color.opacity(0.38))
                                                .frame(width: max(6, w * Double(party.councilsWon) / Double(most)))
                                            if party.majorityWon > 0 {
                                                Capsule().fill(color.gradient)
                                                    .frame(width: max(6, w * Double(party.majorityWon) / Double(most)))
                                            }
                                        }
                                    }
                                    .frame(height: 8)
                                    HStack(spacing: 2) {
                                        Text("\(party.councilsWon)").font(.system(size: 11, weight: .bold, design: .rounded))
                                        Text("· \(party.majorityWon)").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }
                                    .monospacedDigit()
                                    .frame(width: 44, alignment: .trailing)
                                }
                                .help("\(catalog.fullName(party.id, ballotName: party.name)): largest party in \(party.councilsWon) councils, outright majority in \(party.majorityWon)")
                            }
                        }
                    }
                }
            }

            if let b = store.ballots {
                Card(padding: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel(text: "Ballots counted")
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                            GridRow {
                                BallotStat(title: "Ballots cast", value: Fmt.compact(b.ballotsCast))
                                BallotStat(title: "Valid", value: Fmt.compact(b.validVotes))
                                BallotStat(title: "Spoilt", value: Fmt.compact(b.spoiltVotes),
                                           detail: b.ballotsCast > 0 ? Fmt.pct(Double(b.spoiltVotes) / Double(b.ballotsCast) * 100) : nil)
                            }
                            GridRow {
                                BallotStat(title: "Special votes", value: Fmt.compact(b.specialVotes))
                                BallotStat(title: "Registered", value: Fmt.compact(p.registeredVoters))
                                BallotStat(title: "Wards done", value: Fmt.grouped(p.wardsComplete),
                                           detail: "of \(Fmt.grouped(p.wardsExpected))")
                            }
                        }
                        Text("Voters cast two or three ballots each (ward, PR and district), so ballots are not voters.")
                            .font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

private struct LegendItem: View {
    let color: Color
    let label: String
    let value: Int
    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
            Text("\(value)").font(.system(size: 10.5, weight: .bold, design: .rounded)).monospacedDigit()
        }
    }
}

private struct LegendSwatch: View {
    let opacity: Double
    let label: String
    var body: some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(Color.primary.opacity(opacity * 0.6)).frame(width: 8, height: 8)
            Text(label).font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
    }
}

private struct BallotStat: View {
    let title: String
    let value: String
    var detail: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9.5)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 14, weight: .bold, design: .rounded)).monospacedDigit()
                if let detail { Text(detail).font(.system(size: 9.5)).foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - Stale data banner

private struct StaleBanner: View {
    let store: ElectionStore

    var body: some View {
        let offline = !store.isOnline || store.state == .offline
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: offline ? "wifi.slash" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(offline ? Color.secondary : Theme.hung)
            VStack(alignment: .leading, spacing: 1) {
                Text(offline ? "Offline — showing the last results Tally saved" : "Can’t reach the IEC — showing the last good results")
                    .font(.system(size: 11, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    Text(detail(now: context.date, offline: offline))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if !offline {
                Button("Retry") { store.refreshNow() }.controlSize(.small)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill((offline ? Color.secondary : Theme.hung).opacity(0.12)))
    }

    private func detail(now: Date, offline: Bool) -> String {
        var parts: [String] = []
        if let asOf = store.dataAsOf {
            parts.append("IEC report \(asOf.formatted(date: .abbreviated, time: .shortened))")
        }
        if offline {
            parts.append("updates resume automatically when you’re back online")
        } else if let next = store.nextRefreshAt {
            let s = max(0, Int(next.timeIntervalSince(now)))
            parts.append(s >= 60 ? "retrying in \(s / 60) min" : "retrying in \(s) s")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Placeholder (loading / awaiting / error with no data yet)

private struct PlaceholderCard: View {
    let store: ElectionStore

    var body: some View {
        Card(padding: 20) {
            VStack(spacing: 10) {
                switch store.state {
                case .awaiting:
                    Image(systemName: "hourglass").font(.system(size: 28)).foregroundStyle(Theme.hung)
                    Text("Awaiting results capture").font(.headline)
                    Text("The IEC has not published 2026 results yet. Tally checks every minute.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                case .offline:
                    Image(systemName: "wifi.slash").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("You’re offline").font(.headline)
                    Text("Tally will fetch results as soon as your connection is back.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                case .error(let message):
                    Image(systemName: "wifi.exclamationmark").font(.system(size: 28)).foregroundStyle(.secondary)
                    Text("Can’t reach the IEC").font(.headline)
                    Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Try again") { store.refreshNow() }
                default:
                    ProgressView().controlSize(.regular)
                    Text("Fetching live results…").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
        }
    }
}

// MARK: - Footer

private struct FooterView: View {
    let store: ElectionStore
    let monitor: ResourceMonitor
    @Binding var showResources: Bool
    var onQuit: () -> Void
    var onUninstall: () -> Void

    @AppStorage(Prefs.menuBarStyle) private var style = MenuBarStyle.share.rawValue
    @AppStorage(Prefs.showDot) private var showDot = true
    @AppStorage(Prefs.showProgress) private var showProgress = false
    @AppStorage(Prefs.showMonitor) private var showMonitor = true
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        HStack(spacing: 8) {
            Link(destination: ResultsAPI.dashboardURL) {
                HStack(spacing: 3) {
                    Text("Source: IEC")
                    Image(systemName: "arrow.up.right").font(.system(size: 7.5, weight: .bold))
                }
            }
            .font(.system(size: 10, weight: .medium))
            .help("Open the official IEC results dashboard")

            Spacer()

            if showMonitor {
                ResourceMeter(monitor: monitor, store: store, expanded: $showResources)
            }

            Menu {
                Picker("Menu bar shows", selection: $style) {
                    ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.inline)
                Toggle("Party colour dot", isOn: $showDot)
                Toggle("Count progress in menu bar", isOn: $showProgress)
                Toggle("Resource monitor", isOn: $showMonitor)
                Divider()
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        LoginItem.set(on)
                        launchAtLogin = LoginItem.isEnabled
                    }
                Divider()
                Button("Refresh now") { store.refreshNow() }
                Button("Open IEC results dashboard") { NSWorkspace.shared.open(ResultsAPI.dashboardURL) }
                Divider()
                Button("Uninstall Tally…", action: onUninstall)
                Button("Quit Tally", action: onQuit)
            } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 11.5))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings")
        }
        .onAppear { launchAtLogin = LoginItem.isEnabled }
    }
}
