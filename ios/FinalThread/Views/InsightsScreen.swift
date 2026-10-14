import SwiftUI

/// Output of ml/train.py (bundled as insights.json).
struct Insights: Decodable {
    struct ModelScore: Decodable { let mae: Double; let baseline_mae: Double }
    struct Models: Decodable { let stress: ModelScore; let feeling: ModelScore? }
    struct EventSummary: Decodable {
        let title: String
        let n: Int
        let stress: Double?
        let feeling: Double?
    }
    struct Words: Decodable { let stress_up: [String]; let stress_down: [String] }

    let n_events: Int
    let n_rated: Int
    let models: Models
    let events: [EventSummary]
    let words: Words

    static let bundled: Insights? = Bundle.main.url(forResource: "insights", withExtension: "json")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(Insights.self, from: $0) }
}

/// Insights: what the ML model learned, opened from "Explore insights".
struct InsightsScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let openEvent: (String) -> Void
    @State private var expanded: Set<String> = []
    /// A keyword chip acting as a filter on Drains / Lifts.
    @State private var filter: String?
    private let insights = Insights.bundled

    /// Soft spring with one small overshoot, shared with the chart highlight.
    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.72)

    var body: some View {
        VStack(spacing: 0) {
            NavBar(title: "INSIGHTS", back: { dismiss() }) { Color.clear }
                .padding(.top, 14)
            ScrollView {
                content.padding(.top, 20).padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let ins = insights {
            let matching = ins.events.filter { event in filter.map { Self.matches(event.title, $0) } ?? true }
            // Each event goes in one list only: above your average stress it drains, below it lifts.
            let stresses = ins.events.compactMap(\.stress)
            let avgStress = stresses.reduce(0, +) / Double(max(stresses.count, 1))
            let drains = matching.filter { ($0.stress ?? -1) >= avgStress }.sorted { $0.stress! > $1.stress! }.prefix(3)
            let lifts = matching.filter { $0.stress.map { $0 < avgStress } ?? false }.sorted { $0.stress! < $1.stress! }.prefix(3)

            VStack(spacing: 28) {
                if let top = ins.events.filter({ $0.stress != nil }).max(by: { $0.stress! < $1.stress! }),
                   let calm = ins.events.filter({ $0.stress != nil }).min(by: { $0.stress! < $1.stress! }) {
                    coachMessage("Across \(ins.n_events) events, \(top.title) drains you the most and \(calm.title) is your calmest. Tap a word to filter, or a row to see each time it happened.")
                }
                words("LINKED TO STRESS", ins.words.stress_up)
                words("LINKED TO CALM", ins.words.stress_down)
                if let filter {
                    HStack(spacing: 8) {
                        Text("SHOWING EVENTS WITH").caps(11, color: Theme.muted)
                        Text("\"\(filter.uppercased())\"").caps(11, color: Theme.indigoText)
                        Spacer()
                        Button("CLEAR") { withAnimation(spring) { self.filter = nil } }
                            .font(.system(size: 11, weight: .bold)).tracking(1.3)
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, Theme.gutter)
                    .transition(.opacity)
                }
                group("DRAINS", trailing: "AVG STRESS") {
                    if drains.isEmpty { emptyFilter }
                    ForEach(Array(drains.enumerated()), id: \.element.title) { i, e in
                        if i > 0 { DottedLine().padding(.horizontal, Theme.gutter).padding(.vertical, 8) }
                        expandableRow(e.title, fraction: e.stress! / 3, score: String(format: "%.1f", e.stress!),
                                      fallbackCount: e.n, kind: .stress)
                    }
                }
                group("LIFTS", trailing: "AVG STRESS") {
                    if lifts.isEmpty { emptyFilter }
                    ForEach(Array(lifts.enumerated()), id: \.element.title) { i, e in
                        if i > 0 { DottedLine().padding(.horizontal, Theme.gutter).padding(.vertical, 8) }
                        expandableRow(e.title, fraction: e.stress! / 3, score: String(format: "%.1f", e.stress!),
                                      fallbackCount: e.n, kind: .stress)
                    }
                }
            }
        } else {
            coachMessage("No model yet. Export your labels from the gear menu, then run ml/train.py.")
        }
    }

    /// Every past occurrence of an event title, newest first.
    private func occurrences(_ title: String) -> [ScoredItem] {
        store.scoredByDay.values.flatMap { $0 }
            .filter { !$0.isBlock && $0.hasData && $0.title == title }
            .sorted { $0.start > $1.start }
    }

    /// kind: .stress lists each time's stress; otherwise how it felt.
    private func expandableRow(_ title: String, fraction: Double, score: String, fallbackCount: Int, kind: Metric) -> some View {
        let occ = occurrences(title)
        let count = occ.isEmpty ? fallbackCount : occ.count
        let open = expanded.contains(title)
        return VStack(spacing: 0) {
            Button {
                withAnimation(spring) {
                    if open { expanded.remove(title) } else { expanded.insert(title) }
                }
            } label: {
                ThreadRow(name: title, meta: "\(count) event\(count == 1 ? "" : "s")", fraction: fraction, score: score,
                          nameFirst: true,
                          accessory: AnyView(Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.muted)
                            .rotationEffect(.degrees(open ? 180 : 0))))
            }
            .buttonStyle(.plain)
            .accessibilityHint(open ? "Hides each time it happened" : "Shows each time it happened")

            if open {
                occurrenceList(occ, kind: kind)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)).combined(with: .offset(y: -6)),
                        removal: .opacity))
            }
        }
    }

    @ViewBuilder
    private func occurrenceList(_ occ: [ScoredItem], kind: Metric) -> some View {
        if occ.isEmpty {
            Text("No recent events with this name.")
                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.gutter).padding(.top, 10)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(occ.enumerated()), id: \.element.id) { i, e in
                    if i > 0 { Rectangle().fill(Theme.cardLine).frame(height: 1) }
                    Button { openEvent(e.id) } label: {
                        HStack(spacing: 10) {
                            Text(e.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()).caps(11)
                            Text(e.start.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                            Spacer()
                            value(for: e, kind: kind)
                        }
                        .frame(minHeight: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .card(radius: 12)
            .padding(.horizontal, Theme.gutter)
            .padding(.top, 10)
        }
    }

    @ViewBuilder
    private func value(for e: ScoredItem, kind: Metric) -> some View {
        if kind == .stress {
            Text(String(format: "%.1f", e.stress)).font(.number(17)).foregroundStyle(StressLevel(e.stress).color)
        } else if let f = store.feelings[e.id].flatMap(Feeling.init) {
            Text(f.label).font(.number(15)).foregroundStyle(f.color)
        } else {
            Text("NOT RATED").caps(9, color: Theme.faint)
        }
    }

    private var emptyFilter: some View {
        Text("No events with this word.")
            .font(.system(size: 13)).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.gutter)
    }

    /// A keyword (one or two words from the model, e.g. "lunch sam") matches a title that
    /// contains every one of its words.
    static func matches(_ title: String, _ keyword: String) -> Bool {
        let words = Set(title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return keyword.lowercased().split(separator: " ").allSatisfy { words.contains(String($0)) }
    }

    private func coachMessage(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            WhoopBadge(size: 24)
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Color.white.opacity(0.88))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.gutter)
    }

    private func group<Content: View>(_ title: String, trailing: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 16) {
            SectionHeader(title: title) { Text(trailing).caps(12, color: Theme.muted) }
            VStack(spacing: 0, content: content)
        }
    }

    @ViewBuilder
    private func words(_ title: String, _ words: [String]) -> some View {
        if !words.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: title)
                FlowLayout(spacing: 8) {
                    ForEach(words, id: \.self) { w in
                        let on = filter == w
                        Button {
                            withAnimation(spring) { filter = on ? nil : w }
                        } label: {
                            Text(w.uppercased())
                                .caps(10, color: on ? .white : .white.opacity(0.85))
                                .lineLimit(1)
                                .padding(.horizontal, 14)
                                .frame(height: 32)
                                .background(Capsule().fill(on ? Theme.indigo.opacity(0.35) : Theme.card))
                                .overlay(Capsule().stroke(on ? Theme.indigo : Theme.cardLine, lineWidth: on ? 1.5 : 1))
                                .scaleEffect(on ? 1.04 : 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityHint(on ? "Clears the filter" : "Shows only events with this word")
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
        }
    }
}
