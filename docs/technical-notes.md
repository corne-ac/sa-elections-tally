# Technical notes

A native macOS menu bar app that shows the live 2026 Local Government Election results from the
Electoral Commission of South Africa (IEC). It is light on resources, it keeps working offline, and you can
uninstall it from its own menu.

- **Menu bar:** shows the leading party's initials and its share, for example `● ANC 31,9%`. You can
  switch to the lead margin (`ANC +5,0`) or the top two parties (`ANC 32 · DA 27`), and add the count
  progress. When the data is stale, the label dims and shows `⚠︎` (IEC unreachable) or `⌁` (offline).
- **Click it** to open the dashboard:
  - **Hero card:** the leader, their share, lead, swing since 2021, seats and councils.
  - **Count progress:** its own card. It shows the share of voting districts counted in large type, a progress bar, how many are counted and how many are left, and an estimated time to finish once Tally has seen enough of the counting pace (marked ≈). Below that are progress bars for wards, councils and seats.
  - **Parties:** every party's share, votes, seats, councils and swing since 2021.
  - **Map:** all 213 municipalities, coloured by the leading party and fainter where less of the count is in.
    Hover or click for details, zoom to a province, or pinch and drag on the trackpad. You can also colour
    the map by province. **Click shows details; double-click zooms in one level:
    South Africa → province → municipality → wards → voting stations** (see below).
  - **Provinces:** all nine provinces. Click one to see its full party list, swing and council status.
  - **Metros:** the eight metros, each with its leader, top three parties, progress, majority threshold and status.
    Click a card to open that metro's wards on the map.
  - **Councils:** councils controlled, hung, drawn or still pending, councils won per party, and ballot totals.
  - **Resource monitor:** a small pill in the footer showing Tally's own CPU, memory and data use. Click it for graphs and counters.
- **Right-click** the menu bar item for Refresh, Open IEC dashboard, Uninstall and Quit.

> Unofficial viewer. All figures are the IEC's own data; Tally doesn't change them or make projections.
> Always check the official dashboard before you quote results.

## Wards and voting stations (the deepest level)

One rule at every level: **click** selects and shows details, **double-click** zooms in one level,
double-clicking a neighbour moves sideways to it, and double-clicking empty space, **Esc** or ‹ goes back up.

| Level | How to get there | What you see |
|---|---|---|
| Province | Double-click it on the country map, or pick it from the **South Africa ▾** menu | Its municipalities coloured by leader; the rest of the country faded. Legend counts that province only. |
| Municipality | Double-click it in its province, or select it and click **Wards ›** | Every ward coloured by its ward-ballot leader, fainter where fewer stations are counted. Below the map, a tile for each ward, plus how many wards are decided and how many stations are counted. |
| Ward | Double-click a ward, click its tile, or select it and click **Stations ›** | Voting-district outlines coloured by each station's leader (grey means not counted yet). Below the map: the elected councillor once declared, the ward-ballot breakdown, and **every voting station by name with its tally**. |

- **Moving around:** use the breadcrumbs (South Africa ▾ › GP › Johannesburg › Ward 23), ‹ or Esc to go back.
- **Testing the click rules:** they live in `MapNavigation.swift`, separate from the UI. `make test` runs 18 checks covering every level.
- **How "counted" is worked out:** the IEC leaves ward and station progress fields empty, so a station counts as captured once it reports votes. The councillor's name appears only after the IEC declares the ward.
- **Sanity check:** Nelson Mandela Bay ward 41 shows councillor Luyanda Niebeck Lawu (ANC, 35.0% of the ward ballot). One of its stations, Khayamnandi Community Centre, goes SACP at 57.4%.

**Cost.** Nothing loads until you drill in, and everything is cached compressed for offline use:

| Data | Source file | Over the wire | When it's fetched |
|---|---|---|---|
| Ward leaders, nationwide | `MapsJason/2026/EEID1887BigMapsNational.js` | ~37 KB, or 304 | Every 60 s, only while a municipality or ward is open |
| Ward and station results | `MapsJason/2026/EEID1887Munic{id}.js` | 90–480 KB, or 304 | On open, then every 2 min while open |
| Ward outlines | `ElectionMap/MapData/2026/municward{id}.js` | 50–90 KB | On open, then once per launch at most |
| Station outlines | `ElectionMap/MapData/2026/municvd{id}.js` | 90–180 KB | On first ward opened in that municipality |
| Station names (all 20,900) | `ElectionMap/MapData/vs.js` | ~240 KB | Once, ever (cached) |

- **Size:** Johannesburg's results file is 17.5 MB uncompressed, and 85% of it is zero-vote rows. A single byte-level pass (`ZeroVoteFilter.swift`) strips those rows before decoding. That cuts the parse from ~150 ms and a 112 MB peak to ~35 ms and a 37 MB peak, with results identical to a full parse.
- **Measured:**
  - Opening Johannesburg takes ~0.5 s cold and ~0.15 s cached.
  - The drill-down adds at most ~45 MB, briefly, for the largest metro.
  - Two fully explored metros add ~1 MB to the offline cache. The cache limits itself to 25 MB.
- **When you close the dashboard:** drill-down refreshes stop and its data is released from memory.
- **Offline:**
  - A municipality you've opened before still opens, with "Offline — showing saved ward data".
  - One you haven't says "wards load once you're back online".

## Uninstall

You can uninstall Tally in any of three ways. Each one removes the app, its settings, its offline cache, its login item and any crash logs:

1. **From the app:** click the menu bar item → ⚙️ → **Uninstall Tally…**. Alternatively, right-click the menu bar item → **Uninstall Tally…**.
2. **From Terminal:** `./scripts/uninstall.sh`. This also deletes `.build/` and `dist/`, then checks `~/Library` for leftovers and reports what it finds.
3. **Without the source:** `~/Applications/Tally.app/Contents/MacOS/Tally --uninstall`

The source folder stays where it is. Delete it yourself if you want it gone.

### What Tally writes to your Mac

| Item | When | Removed by uninstall |
|---|---|---|
| `~/Applications/Tally.app` | On install | ✓ |
| `~/Library/Caches/local.tally.sa-elections/` (~0.3 MB core, plus ~0.5 MB per municipality you drill into, capped at 25 MB; LZFSE-compressed) | After the first successful fetch: the offline copy of the results | ✓ |
| `~/Library/Preferences/local.tally.sa-elections.plist` | Only after you change a setting | ✓ |
| Login item (Background Task Management) | Only if you turn on "Open at login" | ✓ (unregistered through `SMAppService`) |
| HTTP cache, cookies, notifications, Keychain, privacy permissions | Never | n/a |

## Data source

The IEC dashboard (<https://results.elections.org.za/dashboards/lge/>) has **no documented public API**.
Its JavaScript reads static JSON files that the IEC rewrites throughout the count. Tally reads the same files.

| File | Contents | Over the wire | When Tally fetches it |
|---|---|---|---|
| `MapsJason/2026/EEID1887LiteMapsNational.js` | National results, progress, councils, and province and municipality summaries | ~30 KB gzip, or **0 bytes (304)** when unchanged | Every 60 s |
| `MapsJason/2026/EEID1887Province{1-9}.js` | Full party list per province; top 3 per municipality | 7–14 KB each, or 304 | **Only while the dashboard is open** |
| `MapsJason/2021/EEID1091LiteMapsNational.js` | Final 2021 results (swing baseline) | ~24 KB | Once, then cached for good |
| `MapsJason/2026/PartyList.js` | Party abbreviations and colours | ~60 KB, or 304 | Once per launch |
| `ElectionMap/MapData/2026/nationalMunic.js` | Municipal boundaries (10 MB GeoJSON) | **Never at runtime.** Pre-simplified into the bundled `Resources/sa-map.json` (124 KB) by `scripts/build-map.py` | — |

At launch, Tally reads the electoral event IDs from the dashboard page. The IDs in the table are the fallback.

**Points to note**
- The files are undocumented. If the IEC changes the format, Tally shows **STALE** and keeps the last good data.
  Decoding is lenient, so a missing field shows as zero instead of crashing the app.
- In municipal elections each voter casts 2–3 ballots (ward, PR and district). The IEC's "votes cast" figure counts
  ballots, not voters, so Tally doesn't show turnout.
- Numbers follow your Mac's region settings, for example `31,94%` and `10 237` with South African settings.

## Failsafe behaviour

| Situation | What Tally does |
|---|---|
| No internet at launch | Shows the last saved results straight away from the offline cache, with an **OFFLINE** banner. Never shows a blank window or crashes. |
| Connection drops | Stops polling (no wasted wake-ups), dims the menu bar label and marks it `⌁`. Refreshes about 2 s after the connection returns. |
| IEC down or timing out | Keeps the last good results, shows **STALE** with a Retry button, and backs off: 1 → 2 → 4 → 8 → 10 min. |
| Captive portal, maintenance page or corrupt JSON | Rejects the response (it must decode and pass sanity checks) and keeps the last good results. |
| Results not published yet (404) | Shows **AWAITING** and checks every 5 minutes. |
| Mac goes to sleep | Pauses entirely, then refreshes 5 s after wake. |
| Count finished | Shows **FINAL** and checks every 15 minutes. |
| Low Power Mode | Doubles every interval. |
| Launched twice | The second copy exits quietly, so you never get two menu bar items. |
| Map data missing | The Map tab says so. Everything else keeps working. |

I tested these cases with a dead server, a fake captive-portal page, a 404 server, a cold start with no cache and a warm restart. Dev-only overrides: `TALLY_BASE_URL`, `TALLY_MAP_BASE_URL` and `TALLY_CACHE_DIR`. `TALLY_SNAPSHOT_DRILL=3003:79800023` makes `--snapshot` render a drilled-in ward.

## Lightweight by design

**When the dashboard is closed, nothing runs except the once-a-minute check of one small file.** The dashboard view is
built when you open it and torn down when you close it, so no animation, timer or layout keeps working in the background.
Freed parse buffers are handed back to macOS straight away. (Before 1.2.1, the pulsing LIVE dot kept redrawing after
the dashboard closed and used about 23% CPU. A real-screen check found it; the dot is now static.)

- Uses **gzip and conditional requests** (`If-None-Match` / `If-Modified-Since`). An unchanged file costs a 304 with no body and no JSON decoding.
- In the background it fetches **one file a minute**. Province files load only while you're looking at the dashboard.
- The **map geometry is bundled** and simplified from 237,000 points to 22,700. It loads only the first time you open the Map tab.
- Timers have tolerance, so macOS can group wake-ups together. The pulse animation, the clocks and the resource sampler run only while the dashboard is open.
- Uses no web views and no third-party code.

## Install

You need macOS 14 or later and the Xcode command line tools (`swift`). Admin rights aren't needed.

```bash
./scripts/install.sh      # build, install to ~/Applications, launch
```

Other commands: `make run` (run from `dist/` without installing), `make test` (map click-rule tests) and `make snapshot` (render the live dashboard to `./snapshots`).
Run `python3 scripts/build-map.py <nationalMunic.js> <nationalProvince.js> Resources/sa-map.json` again only if the IEC re-demarcates.

## Project layout

```
Package.swift                 Swift package (no dependencies)
Sources/Tally/
  App.swift                   Entry point, status item, popover, preferences, login item, CLI flags
  ResultsAPI.swift            IEC client: conditional GETs, gzip, network meter, offline disk cache
  ElectionStore.swift         @Observable state + scheduler (network path, sleep/wake, backoff, power)
  Models.swift                Lenient Codable models for the IEC schema
  PartyCatalog.swift          Abbreviations, display names, readable colours
  MapView.swift               Bundled SA geometry + interactive map, breadcrumbs, ward tiles, station list
  MapNavigation.swift         Click / double-click rules per level (pure logic, tested by Tests/MapNavigation)
  DrillDown.swift             Municipality → ward → station loading, refresh and memory release
  Geo.swift                   Albers projection (shared with build-map.py), Douglas–Peucker, GeoJSON → shapes
  ZeroVoteFilter.swift        Strips zero-vote rows from municipality files before decoding
  DashboardView.swift         Dashboard: hero, progress, tabs, stale banner, footer
  ResourceMonitor.swift       In-app CPU, memory, wake-up and network monitor
  Uninstaller.swift           Shared uninstall logic (menu command and --uninstall)
  Components.swift            Cards, rings, split bars, badges, formatting
  Snapshot.swift              `--snapshot <dir>` renders every view offscreen (dev aid and tests)
Resources/                    Info.plist (menu bar only), sa-map.json (bundled boundaries)
scripts/                      build.sh, install.sh, uninstall.sh, build-map.py, make-icon.swift
```
