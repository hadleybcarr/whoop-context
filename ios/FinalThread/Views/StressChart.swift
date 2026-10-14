import Charts
import SwiftUI

/// Stress Monitor–style line chart: 0–3 grid (or heart rate), shaded event bands, an optional
/// highlighted span, and a dashed "now" line with a dot at the latest reading.
struct StressChart: View {
    @Environment(AppStore.self) private var store
    let from: Date
    let to: Date
    var baseline: Double?
    var bands: [ScoredItem] = []
    /// Unscheduled stretches, drawn as dashed purple outlines.
    var free: [ScoredItem] = []
    /// The whole stretch behind a partial overlay (when naming part of a block).
    var extent: (start: Date, end: Date)?
    var overlay: (start: Date, end: Date)?
    var now: Date?
    var labels: [Date]

    /// The highlight opens out from its center when the chart appears.
    @State private var revealed = false
    /// Soft spring with one small, quick overshoot.
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.68)

    var body: some View {
        let metric = store.metric
        let points = store.samples(from: from, to: to).compactMap { s -> (Date, Double)? in
            let v = metric == .hr ? s.bpm : s.stress
            return v.map { (s.t, $0) }
        }
        let (domain, ticks) = scale(points.map(\.1))

        Chart {
            ForEach(bands.filter { $0.start < to && $0.end > from }) { b in
                RectangleMark(xStart: .value("Start", max(b.start, from)), xEnd: .value("End", min(b.end, to)))
                    .foregroundStyle(Theme.band)
            }
            if let span = shownOverlay {
                RectangleMark(xStart: .value("Start", span.start), xEnd: .value("End", span.end))
                    .foregroundStyle(Theme.threadStart.opacity(0.34))
                    .cornerRadius(5)
            }
            if metric == .hr, let baseline {
                RuleMark(y: .value("Baseline", baseline))
                    .foregroundStyle(Theme.muted)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 5]))
            }
            ForEach(points, id: \.0) { t, v in
                LineMark(x: .value("Time", t), y: .value(metric.label, v))
                    .foregroundStyle(lineStyle(metric))
                    .lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            }
            if let now, let last = points.last {
                RuleMark(x: .value("Now", now))
                    .foregroundStyle(Color.white.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                PointMark(x: .value("Time", last.0), y: .value(metric.label, last.1))
                    .foregroundStyle(metric == .stress ? StressLevel(last.1).color : .white)
                    .symbolSize(60)
            }
        }
        .chartBackground { proxy in
            GeometryReader { geo in
                if let plot = proxy.plotFrame.map({ geo[$0] }) {
                    ForEach(Array(freeSpans.enumerated()), id: \.offset) { _, span in
                        if let x0 = proxy.position(forX: max(span.start, from)), let x1 = proxy.position(forX: min(span.end, to)) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Theme.threadStart.opacity(0.1))
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(Theme.threadDot.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                                .frame(width: max(1, x1 - x0), height: plot.height)
                                .position(x: plot.minX + (x0 + x1) / 2, y: plot.midY)
                        }
                    }
                }
            }
        }
        .chartXScale(domain: from...to)
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(position: .leading, values: ticks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.1))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(metric == .stress ? String(format: "%.1f", v) : "\(Int(v))")
                            .font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: labels) { value in
                AxisValueLabel(anchor: value.index == 0 ? .topLeading : (value.index == labels.count - 1 ? .topTrailing : .top)) {
                    if let d = value.as(Date.self) {
                        Text(d.formatted(date: .omitted, time: .shortened))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(value.index == labels.count - 1 ? .white : Theme.muted)
                    }
                }
            }
        }
        .animation(Self.spring, value: shownOverlay?.start)
        .animation(Self.spring, value: shownOverlay?.end)
        .onAppear { withAnimation(Self.spring) { revealed = true } }
        .frame(height: 170)
        .padding(.leading, 12)
        .padding(.trailing, Theme.gutter)
        .accessibilityLabel("\(metric.label) from \(from.formatted(date: .omitted, time: .shortened)) to \(to.formatted(date: .omitted, time: .shortened))")
    }

    private var freeSpans: [(start: Date, end: Date)] {
        (free.map { ($0.start, $0.end) } + (extent.map { [$0] } ?? []))
            .filter { $0.start < to && $0.end > from }
    }

    private var shownOverlay: (start: Date, end: Date)? {
        guard let overlay else { return nil }
        if revealed { return overlay }
        let mid = Date(timeIntervalSince1970: (overlay.start.timeIntervalSince1970 + overlay.end.timeIntervalSince1970) / 2)
        return (mid, mid)
    }

    private func lineStyle(_ metric: Metric) -> AnyShapeStyle {
        guard metric == .stress else { return AnyShapeStyle(Color.white) }
        return AnyShapeStyle(LinearGradient(stops: [
            .init(color: Theme.stressLow, location: 0), .init(color: Theme.stressMedium, location: 0.4),
            .init(color: Theme.yellow, location: 0.7), .init(color: Theme.stressHigh, location: 1),
        ], startPoint: .bottom, endPoint: .top))
    }

    /// Stress uses WHOOP's fixed 0–3 scale; heart rate fits the data and baseline in steps of 10.
    private func scale(_ values: [Double]) -> (ClosedRange<Double>, [Double]) {
        if store.metric == .stress { return (0...3, [0, 1, 2, 3]) }
        let all = values + (baseline.map { [$0] } ?? [])
        let lo = (((all.min() ?? 50) - 4) / 10).rounded(.down) * 10
        let hi = (((all.max() ?? 100) + 4) / 10).rounded(.up) * 10
        return (lo...hi, Array(stride(from: lo, through: hi, by: 10)))
    }
}
