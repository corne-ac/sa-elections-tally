import SwiftUI

// MARK: - Formatting (follows the Mac's region settings)

enum Fmt {
    static func pct(_ value: Double, digits: Int = 1) -> String {
        (value / 100).formatted(.percent.precision(.fractionLength(digits)))
    }
    static func num0(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0))) }
    static func num1(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(1))) }
    static func signed(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(digits)).sign(strategy: .always()))
    }
    static func grouped(_ value: Int) -> String { value.formatted(.number) }
    /// Two significant digits from 1 000 up ("2,6K", "18K"): for tight spots, with full numbers in tooltips.
    static func short(_ value: Int) -> String {
        value < 1_000 ? value.formatted(.number)
            : value.formatted(.number.notation(.compactName).precision(.significantDigits(2)))
    }
    static func compact(_ value: Int) -> String {
        value < 10_000 ? value.formatted(.number)
            : value.formatted(.number.notation(.compactName).precision(.significantDigits(3)))
    }
}

// MARK: - Design tokens

enum Theme {
    static let corner: CGFloat = 14
    static let saGreen = Color(hex: "#007A4D")
    static let saGold = Color(hex: "#FFB612")
    static let saRed = Color(hex: "#DE3831")
    static let saBlue = Color(hex: "#002395")

    static let controlled = Color(hex: "#30B65A")
    static let hung = Color(hex: "#F29B1D")
    static let drawn = Color(hex: "#A06CD5")
    static let pending = Color.secondary.opacity(0.35)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 12
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .fill(tint.map { AnyShapeStyle(LinearGradient(colors: [$0.opacity(0.24), $0.opacity(0.05)],
                                                                    startPoint: .topLeading, endPoint: .bottomTrailing)) }
                          ?? AnyShapeStyle(Color.primary.opacity(0.04)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                    .strokeBorder((tint ?? .primary).opacity(tint == nil ? 0.05 : 0.2), lineWidth: 0.5)
            }
    }
}

struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}

/// App mark: a ballot "X" on a tile in the colours of the South African flag.
struct AppMark: View {
    var size: CGFloat = 30
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(AngularGradient(colors: [Theme.saGreen, Theme.saGold, Theme.saRed, Theme.saBlue, Theme.saGreen],
                                      center: .center, angle: .degrees(200)))
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .fill(.black.opacity(0.12))
            Image(systemName: "xmark")
                .font(.system(size: size * 0.46, weight: .black))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 1, y: 0.5)
        }
        .frame(width: size, height: size)
    }
}

struct LiveBadge: View {
    let state: FeedState
    let isFinal: Bool

    var body: some View {
        let (label, color, symbol): (String, Color, String) = {
            switch state {
            case .live where isFinal: return ("FINAL", Theme.controlled, "checkmark.circle.fill")
            case .live: return ("LIVE", Theme.saRed, "circle.fill")
            case .awaiting: return ("AWAITING", Theme.hung, "hourglass")
            case .offline: return ("OFFLINE", .secondary, "wifi.slash")
            case .loading: return ("LOADING", .secondary, "circle.dotted")
            case .error: return ("STALE", .secondary, "exclamationmark.triangle.fill")
            }
        }()
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: symbol == "circle.fill" ? 6 : 9, weight: .bold))
                // Deliberately static: a repeating symbol pulse redraws every frame (~20% CPU while open).
            Text(label).font(.system(size: 9.5, weight: .bold)).tracking(0.6)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct Ring: View {
    let percent: Double
    let tint: Color
    var lineWidth: CGFloat = 5
    var fontSize: CGFloat = 11.5

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, percent / 100)))
                .stroke(tint.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(Fmt.num0(percent) + "%")
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: percent))
        }
        .animation(.smooth(duration: 0.8), value: percent)
    }
}

struct RingStat: View {
    let title: String
    let done: Int
    let total: Int
    let percent: Double
    let tint: Color

    var body: some View {
        VStack(spacing: 5) {
            Ring(percent: percent, tint: tint).frame(width: 46, height: 46)
            Text(title).font(.system(size: 11, weight: .semibold))
            Text("\(Fmt.compact(done)) / \(Fmt.compact(total))")
                .font(.system(size: 9.5))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .help("\(title): \(Fmt.grouped(done)) of \(Fmt.grouped(total)) complete")
    }
}

/// Proportional stacked bar of vote shares.
struct SplitBar: View {
    struct Segment: Identifiable { let id: Int; let value: Double; let color: Color; let label: String }
    let segments: [Segment]
    var height: CGFloat = 12
    var spacing: CGFloat = 1.5

    var body: some View {
        GeometryReader { geo in
            let total = max(segments.reduce(0) { $0 + $1.value }, 0.0001)
            let usable = geo.size.width - spacing * CGFloat(max(segments.count - 1, 0))
            HStack(spacing: spacing) {
                ForEach(segments) { s in
                    Rectangle()
                        .fill(s.color.gradient)
                        .frame(width: max(0, usable * s.value / total))
                        .help("\(s.label) \(Fmt.pct(s.value, digits: 2))")
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.6), value: segments.map(\.value))
    }
}

/// A rounded progress bar with a soft track and a gradient fill.
struct ProgressBar: View {
    let fraction: Double
    let tint: Color
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.15))
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.75), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.8), value: fraction)
    }
}

struct ShareBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(color.gradient).frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: height)
        .animation(.smooth(duration: 0.6), value: fraction)
    }
}

struct SwingLabel: View {
    let swing: Double?
    var suffix = "vs ’21"

    var body: some View {
        if let s = swing {
            let up = s >= 0
            HStack(spacing: 2) {
                Image(systemName: up ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 6.5))
                Text(Fmt.num1(abs(s))).monospacedDigit()
                Text(suffix).foregroundStyle(.secondary)
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(up ? Theme.controlled : Theme.saRed)
            .help("Change in vote share against the 2021 municipal elections (percentage points)")
        }
    }
}

struct PartyDot: View {
    let color: Color
    var size: CGFloat = 8
    var body: some View {
        Circle().fill(color.gradient).frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
    }
}

struct Chip: View {
    let text: String
    var color: Color = .secondary
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule().fill(color.opacity(0.13)))
    }
}
