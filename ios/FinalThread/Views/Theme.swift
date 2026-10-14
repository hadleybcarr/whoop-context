import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// `hex` blended toward `other`: amount 0 is `hex`, 1 is `other`. Opaque, unlike lowering opacity.
    init(hex: UInt32, mixedWith other: UInt32, amount t: Double) {
        func channel(_ shift: UInt32) -> Double {
            let a = Double((hex >> shift) & 0xFF), b = Double((other >> shift) & 0xFF)
            return (a + (b - a) * t) / 255
        }
        self.init(.sRGB, red: channel(16), green: channel(8), blue: channel(0))
    }
}

/// Colors sampled from the WHOOP app, plus the thread component colors from the Figma frame.
enum Theme {
    // Surfaces
    static let bgTop = Color(hex: 0x2B3A45)
    static let bgMid = Color(hex: 0x18212A)
    static let bgBottom = Color(hex: 0x0E1316)
    static let card = Color(hex: 0x1D252C)
    static let cardLine = Color.white.opacity(0.08)
    static let cardRaised = Color(hex: 0x2A333B)
    static let indigo = Color(hex: 0x5A5FE0)
    static let indigoText = Color(hex: 0x7D82FF)
    static let pillOuter = Color(hex: 0x2F3740)
    static let pillInner = Color(hex: 0x444C55)
    static let tabBar = Color(hex: 0x0F1317)
    static let gaugeTrack = Color(hex: 0x252C33)

    // Text
    static let muted = Color.white.opacity(0.6)
    static let faint = Color.white.opacity(0.3)
    static let tabInactive = Color(hex: 0x8A9096)

    // WHOOP metric colors
    static let green = Color(hex: 0x16EC06)
    static let yellow = Color(hex: 0xFEDE08)
    static let red = Color(hex: 0xFF0026)
    static let blue = Color(hex: 0x0093E7)
    static let sleep = Color(hex: 0x7CA1B9)
    static let stressLow = Color(hex: 0x4FA3E3)
    static let stressMedium = Color(hex: 0x00E3A0)
    static let stressHigh = Color(hex: 0xF2A93B)
    static let band = Color(hex: 0x508CC8, opacity: 0.18)

    // Thread component
    static let threadStart = Color(hex: 0x6D4A95)
    static let threadEnd = Color(hex: 0x4A3366)
    static let threadRing = Color(hex: 0x3F2A58)
    static let threadDot = Color(hex: 0x7B55AA)
    static let knob = Color(hex: 0xD9D9D9)
    static let separator = Color(hex: 0xD9D9D9, opacity: 0.22)

    static let gutter: CGFloat = 20
    static let cardRadius: CGFloat = 14

    static let background = LinearGradient(
        stops: [.init(color: bgTop, location: 0), .init(color: bgMid, location: 0.38), .init(color: bgBottom, location: 1)],
        startPoint: .top, endPoint: .bottom
    )
}

/// WHOOP's Stress Monitor bands.
enum StressLevel {
    case low, medium, high

    /// Bands use the value as displayed (one decimal), so "1.0" never reads as LOW.
    init(_ value: Double) {
        let shown = (value * 10).rounded() / 10
        self = shown < 1 ? .low : shown < 2 ? .medium : .high
    }

    var label: String {
        switch self {
        case .low: "LOW"
        case .medium: "MEDIUM"
        case .high: "HIGH"
        }
    }

    var color: Color {
        switch self {
        case .low: Theme.stressLow
        case .medium: Theme.stressMedium
        case .high: Theme.stressHigh
        }
    }

    /// Same colors as hex, for blending.
    var hex: UInt32 {
        switch self {
        case .low: 0x4FA3E3
        case .medium: 0x00E3A0
        case .high: 0xF2A93B
        }
    }
}

// MARK: Type

extension Font {
    /// Big condensed numerals, the closest system match to WHOOP's DIN figures.
    static func number(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight).width(.condensed)
    }
}

extension View {
    /// Uppercase, wide-tracked label used for WHOOP headers, tabs and tiles.
    func caps(_ size: CGFloat = 13, weight: Font.Weight = .bold, color: Color = .white) -> some View {
        font(.system(size: size, weight: weight)).tracking(size * 0.12).foregroundStyle(color)
    }

    func capsLabel(size: CGFloat = 10) -> some View { caps(size, color: Theme.muted) }

    func card(_ color: Color = Theme.card, radius: CGFloat = Theme.cardRadius) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(color))
    }
}

// MARK: Components

/// The WHOOP "W" mark, drawn from the three paths in the brand SVG (viewBox 6…24 × 9.5…22.1).
struct WhoopMark: Shape {
    func path(in rect: CGRect) -> Path {
        let polygons: [[CGPoint]] = [
            [.init(x: 6, y: 9.5), .init(x: 8.55, y: 17.34), .init(x: 10.15, y: 17.34), .init(x: 7.6, y: 9.5)],
            [.init(x: 22.4, y: 9.5), .init(x: 19.1, y: 19.64), .init(x: 17.35, y: 14.26), .init(x: 15.75, y: 14.26),
             .init(x: 18.3, y: 22.1), .init(x: 19.9, y: 22.1), .init(x: 24, y: 9.5)],
            [.init(x: 10.1, y: 22.1), .init(x: 14.2, y: 9.5), .init(x: 15.8, y: 9.5), .init(x: 11.7, y: 22.1)],
        ]
        let sx = rect.width / 18, sy = rect.height / 12.6
        var path = Path()
        for poly in polygons {
            path.addLines(poly.map { CGPoint(x: rect.minX + ($0.x - 6) * sx, y: rect.minY + ($0.y - 9.5) * sy) })
            path.closeSubpath()
        }
        return path
    }
}

/// W in a circle, as on WHOOP insight cards and the top-left of the app.
struct WhoopBadge: View {
    var size: CGFloat = 24
    var filled = false

    var body: some View {
        ZStack {
            if filled { Circle().fill(Color.black) }
            Circle().stroke(Color.white, lineWidth: filled ? 0 : 1.3)
            WhoopMark().fill(.white).frame(width: size * 0.5, height: size * 0.35)
        }
        .frame(width: size, height: size)
    }
}

/// "‹ TODAY ›" row under the page title.
/// WHOOP's Home tabs. This screen is the Context tab; the others live in the WHOOP app.
struct TopTabs: View {
    private let tabs = ["OVERVIEW", "SLEEP", "RECOVERY", "STRAIN", "CONTEXT"]
    private let selected = "CONTEXT"

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                let on = tab == selected
                Text(tab)
                    .caps(11, color: on ? .white : Theme.tabInactive)
                    .fixedSize()
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) {
                        if on { Capsule().fill(.white).frame(height: 2) }
                    }
                    .accessibilityAddTraits(on ? .isSelected : [])
                if tab != tabs.last { Spacer(minLength: 8) }
            }
        }
        .padding(.horizontal, Theme.gutter)
    }
}

struct DateNav: View {
    let label: String
    let canGoBack: Bool
    let canGoForward: Bool
    let back: () -> Void
    let forward: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            chevron("chevron.left", enabled: canGoBack, label: "Previous day", action: back)
            Text(label).caps(12).lineLimit(1).frame(minWidth: 96)
            chevron("chevron.right", enabled: canGoForward, label: "Next day", action: forward)
        }
    }

    private func chevron(_ name: String, enabled: Bool, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(enabled ? .white : Theme.faint)
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

/// Top navigation: back chevron, caps title, trailing action.
struct NavBar<Trailing: View>: View {
    let title: String
    var subtitle: String?
    let back: () -> Void
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Button(action: back) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back")
            Spacer()
            VStack(spacing: 4) {
                Text(title).caps(13).accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).caps(8, color: Theme.muted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.cardRaised))
                }
            }
            Spacer()
            trailing.frame(width: 40, height: 40)
        }
        .padding(.horizontal, 12)
    }
}

/// Section header: caps title on the left, muted comparison label on the right.
struct SectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack {
            Text(title).caps(12)
            Spacer()
            trailing
        }
        .padding(.horizontal, Theme.gutter)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// WHOOP insight box: indigo outline, optional W headline, optional coach link.
struct InsightCard: View {
    var title: String?
    let text: String
    var link: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 8) {
                    WhoopBadge(size: 22)
                    Text(title.uppercased()).caps(12)
                }
            }
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.88))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if let link, let action {
                Button(action: action) {
                    HStack(spacing: 6) {
                        Text(link.uppercased()).caps(11, color: Theme.indigoText)
                        Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.indigoText)
                    }
                }
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: Theme.cardRadius).fill(Theme.indigo.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.indigo, lineWidth: 1))
        .padding(.horizontal, Theme.gutter)
    }
}

enum Trend { case up, down, flat
    init(_ v: Double, eps: Double = 0.03) { self = v > eps ? .up : v < -eps ? .down : .flat }
}

/// Small ▲ / ▼ marker. Up means more stress or heart rate, so it's orange.
struct TrendMark: View {
    let trend: Trend
    var body: some View {
        switch trend {
        case .up: Image(systemName: "arrowtriangle.up.fill").font(.system(size: 7)).foregroundStyle(Theme.stressHigh)
        case .down: Image(systemName: "arrowtriangle.down.fill").font(.system(size: 7)).foregroundStyle(Theme.stressMedium)
        case .flat: Circle().fill(Theme.muted).frame(width: 5, height: 5)
        }
    }
}

/// One row inside a StatGroup: icon, caps label, value, trend.
struct StatRow: View {
    let icon: String
    let label: String
    let value: String
    var unit: String?
    var trend: Trend?
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? Theme.indigoText : Theme.muted)
                .frame(width: 20)
            Text(label).caps(11, color: selected ? Theme.indigoText : .white)
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.number(22))
                if let unit { Text(unit).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted) }
            }
            if let trend { TrendMark(trend: trend).frame(width: 10) }
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// WHOOP's grouped statistics card: rows split by hairlines, optional comparison footer.
struct StatGroup<Content: View>: View {
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            _VariadicView.Tree(DividedLayout()) { content }
            if let footer {
                HStack(spacing: 8) {
                    HStack(spacing: 2) { TrendMark(trend: .up); TrendMark(trend: .down) }
                    Text(footer).font(.system(size: 11)).foregroundStyle(Theme.muted)
                    Spacer()
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.25)))
                .padding(.top, 6).padding(.bottom, 10)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .card()
        .padding(.horizontal, Theme.gutter)
    }

    private struct DividedLayout: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            ForEach(children) { child in
                child
                if child.id != children.last?.id {
                    Rectangle().fill(Theme.cardLine).frame(height: 1)
                }
            }
        }
    }
}

/// Stress Monitor gauge: a 240° arc from low (blue) to high (orange) with a tick at the value.
struct StressGauge: View {
    let value: Double?
    let caption: String

    private let startAngle = 150.0, sweep = 240.0

    var body: some View {
        let level = value.map(StressLevel.init)
        ZStack {
            arc(to: 1)
                .stroke(Theme.gaugeTrack, style: StrokeStyle(lineWidth: 10, lineCap: .round))
            arc(to: 1)
                .stroke(
                    AngularGradient(
                        stops: [
                            .init(color: Theme.stressLow, location: 0),
                            .init(color: Theme.stressMedium, location: 0.33),
                            .init(color: Theme.yellow, location: 0.55),
                            .init(color: Theme.stressHigh, location: 0.67),
                        ],
                        center: .center,
                        startAngle: .degrees(startAngle),
                        endAngle: .degrees(startAngle + 360)
                    ),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .opacity(value == nil ? 0.25 : 1)
            if let value {
                tick(at: value / 3)
            }
            VStack(spacing: 2) {
                Text(value.map { String(format: "%.1f", $0) } ?? "--")
                    .font(.number(68))
                    .contentTransition(.numericText())
                Text(level?.label ?? "NO DATA").caps(14, color: level?.color ?? Theme.muted)
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 2)
            }
            .offset(y: 6)
            HStack {
                Text("0.0")
                Spacer()
                Text("3.0")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 22)
            .offset(y: 70)
        }
        .frame(width: 236, height: 236)
        // The arc is open at the bottom; don't reserve layout space for the empty part.
        .padding(.bottom, -44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Day stress")
        .accessibilityValue(value.map { String(format: "%.1f, %@", $0, StressLevel($0).label.lowercased()) } ?? "no data")
    }

    private func arc(to fraction: Double) -> Path {
        Path { p in
            p.addArc(center: .init(x: 118, y: 118), radius: 104,
                     startAngle: .degrees(startAngle), endAngle: .degrees(startAngle + sweep * fraction), clockwise: false)
        }
    }

    private func tick(at fraction: Double) -> some View {
        let angle = Angle.degrees(startAngle + sweep * max(0, min(1, fraction)))
        return Capsule()
            .fill(.white)
            .frame(width: 3.5, height: 22)
            .shadow(color: .black.opacity(0.5), radius: 2)
            .offset(y: -104)
            .rotationEffect(angle + .degrees(90))
    }
}

/// Dotted separator between thread rows.
struct DottedLine: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                p.move(to: .init(x: 0, y: 0.5))
                p.addLine(to: .init(x: geo.size.width, y: 0.5))
            }
            .stroke(Theme.separator, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .frame(height: 1)
    }
}

/// WHOOP's floating navigation: a glass capsule of tabs. This page lives under Home.
struct WhoopDock: View {
    private let items: [(String, String)] = [
        ("Home", "house"), ("Plan", "list.clipboard"), ("Community", "person.3"), ("More", "line.3.horizontal"),
    ]

    var body: some View {
        HStack {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                VStack(spacing: 3) {
                    Image(systemName: i == 0 ? "\(item.1).fill" : item.1)
                        .font(.system(size: 19))
                        .frame(height: 22)
                    Text(item.0).font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(i == 0 ? .white : Theme.tabInactive)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(i == 0 ? .isSelected : [])
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background(Capsule().fill(.ultraThinMaterial))
        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
        .padding(.horizontal, 12)
    }
}

/// Wraps children onto new lines, each sized to its content (for keyword tags).
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0,
                      height: rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([i], size.width, size.height)
            } else {
                current = (current.indices + [i], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// White rounded-square "+" from WHOOP's My Day header.
struct SquarePlus: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(.white))
        }
        .accessibilityLabel("Add an event")
    }
}
