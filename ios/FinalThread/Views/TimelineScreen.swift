import SwiftUI

struct TimelineScreen: View {
    @Environment(AppStore.self) private var store
    @Binding var selectedId: String?
    let openCoach: () -> Void
    let openInfo: () -> Void

    var body: some View {
        let items = store.items
        let stressItems = items.filter { $0.hasData && !$0.active }
        let avgStress = stressItems.isEmpty ? nil : stressItems.map(\.stress).reduce(0, +) / Double(stressItems.count)

        VStack(spacing: 26) {
            StressGauge(value: avgStress, caption: gaugeCaption)
                .overlay(alignment: .topTrailing) {
                    Button(action: openInfo) {
                        Image(systemName: "info.circle").font(.system(size: 22, weight: .light)).foregroundStyle(.white)
                    }
                    .accessibilityLabel("How stress is scored")
                    .offset(x: 52)
                }

            dayChart(items)

            insight(items: items)

            VStack(spacing: 16) {
                SectionHeader(title: store.dayOffset == 0 ? "TODAY'S THREADS" : "THREADS") {
                    HStack(spacing: 14) {
                        metricMenu
                        if let block = store.latestBlock {
                            SquarePlus { selectedId = block.id }
                        }
                    }
                }
                if items.isEmpty {
                    Text("Nothing on this day yet.")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                        .padding(.vertical, 24)
                } else {
                    rows(items)
                }
            }

            breakdown
        }
    }

    private var gaugeCaption: String {
        store.dayOffset == 0
            ? "Last updated \(store.now.formatted(date: .omitted, time: .shortened))"
            : "Day average"
    }

    /// The day's line with calendar events shaded, like WHOOP's activity bands.
    @ViewBuilder
    private func dayChart(_ items: [ScoredItem]) -> some View {
        if let first = items.first, let lastItem = items.last {
            let isToday = store.dayOffset == 0
            let to = isToday ? store.now : lastItem.end
            let mid = Date(timeIntervalSince1970: (first.start.timeIntervalSince1970 + to.timeIntervalSince1970) / 2)
            VStack(alignment: .leading, spacing: 10) {
                StressChart(
                    from: first.start, to: to,
                    baseline: items.first(where: \.hasData)?.baselineHr,
                    bands: items.filter { !$0.isBlock },
                    free: items.filter(\.isBlock),
                    now: isToday ? store.now : nil,
                    labels: [first.start, mid, to]
                )
                HStack(spacing: 16) {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.band)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.stressLow.opacity(0.35), lineWidth: 1))
                            .frame(width: 12, height: 10)
                        Text("Calendar event")
                    }
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(Theme.threadStart.opacity(0.1))
                            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Theme.threadDot, style: StrokeStyle(lineWidth: 1, dash: [2, 2])))
                            .frame(width: 12, height: 10)
                        Text("Unscheduled")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(Theme.muted)
                .padding(.leading, 40)
                .accessibilityHidden(true)
            }
        }
    }

    // MARK: Insight

    @ViewBuilder
    private func insight(items: [ScoredItem]) -> some View {
        let scored = items.filter { $0.hasData && !$0.active }
        if let peak = scored.max(by: { $0.stress < $1.stress }), let calm = scored.min(by: { $0.stress < $1.stress }) {
            let peakName = peak.isBlock ? "Unscheduled time at \(peak.start.formatted(date: .omitted, time: .shortened))" : peak.title
            let calmName = calm.isBlock ? rangeLabel(calm) : calm.title
            InsightCard(
                text: "\(peakName) was the most stressful part of your day at \(String(format: "%.1f", peak.stress)), with heart rate \(pct(peak.deltaPct)) vs. your baseline. Your calmest stretch was \(calmName) (\(String(format: "%.1f", calm.stress))).",
                link: "Explore insights",
                action: openCoach
            )
        } else {
            InsightCard(text: "Scores appear once WHOOP has heart-rate data for this day.")
        }
    }

    // MARK: Threads

    private var metricMenu: some View {
        @Bindable var store = store
        return Menu {
            Picker("Stat", selection: $store.metric) {
                ForEach(Metric.allCases) { Text($0.label).tag($0) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(store.metric.label.uppercased()).caps(12, color: Theme.muted)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
            }
        }
        .accessibilityLabel("Stat shown, \(store.metric.label)")
    }

    @ViewBuilder
    private func rows(_ items: [ScoredItem]) -> some View {
        let nowIndex = store.dayOffset == 0 ? (items.firstIndex { $0.start > store.now } ?? items.count) : nil
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                if index == nowIndex {
                    NowMarker(now: store.now).padding(.vertical, 8)
                } else if index > 0 {
                    DottedLine().padding(.horizontal, Theme.gutter).padding(.vertical, 8)
                }
                Button { selectedId = item.id } label: { row(item) }
                    .buttonStyle(.plain)
            }
            if nowIndex == items.count {
                NowMarker(now: store.now).padding(.top, 10)
            }
        }
    }

    private func row(_ item: ScoredItem) -> some View {
        let m = item.metrics[store.metric]
        var meta = item.isBlock
            ? "\(item.start.formatted(date: .omitted, time: .shortened)) · \(durationLabel(item))"
            : item.start.formatted(date: .omitted, time: .shortened)
        if !item.hasData { meta += item.start > store.now ? " · upcoming" : " · no data" }
        return ThreadRow(
            name: item.title,
            meta: meta,
            fraction: m?.fraction ?? 0,
            score: m.map { store.metric.format($0.value) },
            isBlock: item.isBlock,
            feeling: store.feelings[item.id].flatMap(Feeling.init)
        )
    }

    // MARK: Stress vs. typical day

    @ViewBuilder
    private var breakdown: some View {
        let day = store.currentDay
        let today = store.stressBreakdown(for: day)
        if today.total > 0 {
            let typical = store.typicalBreakdown(like: day)
            let weekday = day.formatted(.dateTime.weekday(.wide)).uppercased()
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "gauge.with.dots.needle.0percent").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Text("TOTAL DAY").caps(11)
                }
                HStack(spacing: 6) {
                    Text(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()).caps(11)
                    if typical != nil { Text("VS. TYPICAL \(weekday)").caps(11, color: Theme.muted) }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Text(totalDayInsight(day: day, today, typical))
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.82))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: 6) {
                    BreakdownBar(breakdown: today, height: 9)
                    if let typical { BreakdownBar(breakdown: typical, height: 5).opacity(0.45) }
                }
                HStack(alignment: .top) {
                    column(.low, today.low, typical?.low)
                    Spacer()
                    column(.medium, today.medium, typical?.medium)
                    Spacer()
                    column(.high, today.high, typical?.high)
                }

            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .card()
            .padding(.horizontal, Theme.gutter)
        }
    }

    private func column(_ level: StressLevel, _ minutes: Double, _ typical: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(hoursMinutes(minutes)).font(.number(28))
                Text("hrs").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            if let typical, typical > 0 {
                let change = (minutes - typical) / typical
                HStack(spacing: 3) {
                    Image(systemName: change >= 0 ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill").font(.system(size: 8))
                    Text("\(Int(abs(change * 100).rounded()))%").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Theme.muted)
            }
            Text(level.label).caps(10, color: level.color)
        }
    }

    /// One-line summary under Total Day, in the style of WHOOP's Stress Monitor.
    private func totalDayInsight(day: Date, _ b: StressBreakdown, _ typical: StressBreakdown?) -> String {
        let main = [("low", b.low), ("medium", b.medium), ("high", b.high)].max { $0.1 < $1.1 }!.0
        var parts = ["Most of your time was spent in the \(main) stress zone."]
        // Only call out sustained stress; a reading or two above the line isn't a stretch.
        if let run = store.longestHighStretch(on: day), run.minutes >= 10 {
            parts.append("Your longest stretch of high stress started at \(run.start.formatted(date: .omitted, time: .shortened)) and lasted \(run.minutes) minutes.")
        } else {
            parts.append("You had no sustained stretches of high stress.")
        }
        if let t = typical?.high, t > 0 {
            let change = (b.high - t) / t
            if abs(change) >= 0.05 {
                parts.append("That's \(Int((abs(change) * 100).rounded()))% \(change > 0 ? "more" : "less") high stress than a typical \(day.formatted(.dateTime.weekday(.wide))).")
            }
        }
        return parts.joined(separator: " ")
    }

    private func hoursMinutes(_ minutes: Double) -> String {
        let m = Int(minutes.rounded())
        return "\(m / 60):\(String(format: "%02d", m % 60))"
    }
}

/// Low / medium / high minutes as one stacked bar.
struct BreakdownBar: View {
    let breakdown: StressBreakdown
    let height: CGFloat

    var body: some View {
        GeometryReader { geo in
            let total = max(breakdown.total, 1)
            let w = geo.size.width - 4
            HStack(spacing: 2) {
                Rectangle().fill(Theme.stressLow).frame(width: w * breakdown.low / total)
                Rectangle().fill(Theme.stressMedium).frame(width: w * breakdown.medium / total)
                Rectangle().fill(Theme.stressHigh).frame(width: w * breakdown.high / total)
            }
            .clipShape(RoundedRectangle(cornerRadius: height / 3))
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

func rangeLabel(_ item: ScoredItem) -> String {
    "\(item.start.formatted(date: .omitted, time: .shortened)) – \(item.end.formatted(date: .omitted, time: .shortened))"
}

func durationLabel(_ item: ScoredItem) -> String {
    let min = Int((item.end.timeIntervalSince(item.start) / 60).rounded())
    return min < 60 ? "\(min)m" : "\(min / 60)h" + (min % 60 > 0 ? " \(min % 60)m" : "")
}
