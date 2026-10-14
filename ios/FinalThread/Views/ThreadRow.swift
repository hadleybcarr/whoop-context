import SwiftUI

/// The thread: a bar whose length is the score, with the score in the knob at its end.
struct ThreadRow: View {
    let name: String
    let meta: String
    /// 0...1 → bar length.
    let fraction: Double
    let score: String?
    var isBlock = false
    var feeling: Feeling?
    /// Name on the left and meta on the right (Insights rows); timeline rows lead with the time.
    var nameFirst = false
    /// Shown after the meta text, e.g. a drop-down chevron.
    var accessory: AnyView?

    private let barHeight: CGFloat = 26
    private let knob: CGFloat = 22
    private var noData: Bool { score == nil }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                if nameFirst {
                    title
                    Spacer(minLength: 12)
                    metaText
                } else {
                    metaText
                    Spacer(minLength: 12)
                    title
                }
            }
            .padding(.horizontal, Theme.gutter)

            GeometryReader { geo in
                let width = geo.size.width * (noData ? 0.14 : 0.18 + 0.52 * max(0, min(1, fraction)))
                bar
                    .frame(width: max(width, knob + 8), height: barHeight)
                    .animation(.spring(duration: 0.5), value: fraction)
            }
            .frame(height: barHeight)
            .padding(.leading, Theme.gutter)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isBlock ? "Unscheduled, \(meta)" : "\(name), \(meta)")
        .accessibilityValue(score ?? "no data")
    }

    private var metaText: some View {
        HStack(spacing: 6) {
            Text(meta)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted)
            if let feeling {
                Circle().fill(feeling.color).frame(width: 7, height: 7)
            }
            if let accessory { accessory }
        }
    }

    @ViewBuilder
    private var title: some View {
        if isBlock {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle").font(.system(size: 13, weight: .semibold))
                Text("UNSCHEDULED").caps(12, color: Theme.muted)
            }
            .foregroundStyle(Theme.muted)
        } else {
            Text(name.uppercased())
                .caps(13)
                .lineLimit(1)
        }
    }

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(bottomTrailingRadius: barHeight / 2, topTrailingRadius: barHeight / 2)
    }

    private var bar: some View {
        let fill: AnyShapeStyle = noData
            ? AnyShapeStyle(Theme.cardRaised)
            : isBlock
                ? AnyShapeStyle(LinearGradient(colors: [Theme.threadStart.opacity(0.5), Theme.threadEnd.opacity(0.5)], startPoint: .leading, endPoint: .trailing))
                : AnyShapeStyle(LinearGradient(colors: [Theme.threadStart, Theme.threadEnd], startPoint: .leading, endPoint: .trailing))
        let ring = noData ? Theme.card : isBlock ? Theme.threadRing.opacity(0.6) : Theme.threadRing

        return shape
            .fill(fill)
            .background(shape.fill(ring).padding(.vertical, -3).padding(.trailing, -3))
            .overlay(alignment: .trailing) {
                Circle()
                    .fill(noData ? Theme.faint : Theme.knob)
                    .frame(width: knob, height: knob)
                    .overlay {
                        Text(score ?? "")
                            .font(.number(12, weight: .heavy))
                            .foregroundStyle(Color(hex: 0x1A1024))
                            .minimumScaleFactor(0.7)
                    }
                    .padding(.trailing, 2)
            }
    }
}

/// Blue "now" line across today's timeline.
struct NowMarker: View {
    let now: Date

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Theme.blue).frame(height: 2)
            Text("NOW · \(now.formatted(date: .omitted, time: .shortened))")
                .caps(10, weight: .heavy)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Theme.blue))
        }
        .padding(.horizontal, Theme.gutter)
        .accessibilityLabel("Current time")
    }
}
