import Charts
import SwiftUI

/// Detail for an event or unscheduled block, laid out like WHOOP's Stress Monitor: score up top,
/// the chart, statistics rows, then "How did it feel?" (events) or the add-event form (free time).
struct EventSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedId: String?

    /// What's being entered for an unscheduled block. The header, scores and chart follow it.
    @State private var draft = Draft()
    @State private var similarOpen = false
    @FocusState private var headingFocused: Bool

    struct Draft {
        var blockId: String?
        var title = ""
        var start = Date()
        var end = Date()
    }

    var body: some View {
        if let item = selectedId.flatMap(store.item(id:)) {
            let span = item.isBlock ? (draftScore(item) ?? item) : item
            VStack(spacing: 0) {
                topBar(item)
                ScrollView {
                    VStack(spacing: 28) {
                        hero(item, span: span)
                        if item.hasData {
                            chart(item, overlay: span)
                            notes(item)
                            statistics(span)
                        } else {
                            InsightCard(
                                title: item.start > store.now ? "COMING UP" : "NO DATA",
                                text: item.start > store.now
                                    ? "This hasn't happened yet. It will be scored once WHOOP has data for it."
                                    : "No heart-rate readings cover this time."
                            )
                        }
                        if item.isBlock {
                            AddEventForm(block: item, draft: $draft, selectedId: $selectedId)
                        } else {
                            feelings(item)
                            similar(item)
                            if item.isCustom {
                                Button("Remove this event", role: .destructive) {
                                    store.removeCustomEvent(id: item.id)
                                    dismiss()
                                }
                                .font(.system(size: 14, weight: .semibold))
                            }
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 40)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .onChange(of: item.id, initial: true) {
                similarOpen = false
                if item.isBlock && draft.blockId != item.id {
                    draft = Draft(blockId: item.id, start: item.start, end: item.end)
                }
            }
        }
    }

    // MARK: Header

    private func topBar(_ item: ScoredItem) -> some View {
        NavBar(title: store.metric == .stress ? "STRESS MONITOR" : "HEART RATE", back: { dismiss() }) { Color.clear }
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func heading(_ item: ScoredItem) -> String {
        guard item.isBlock else { return item.title.uppercased() }
        let typed = draft.title.trimmingCharacters(in: .whitespaces)
        return typed.isEmpty ? "UNSCHEDULED TIME" : typed.uppercased()
    }

    private func hero(_ item: ScoredItem, span: ScoredItem) -> some View {
        let value = span.metrics[store.metric]?.value
        return VStack(spacing: 6) {
            if item.isBlock {
                // Naming the stretch here or in the form below is the same thing.
                TextField("", text: $draft.title, prompt: Text("UNSCHEDULED TIME").foregroundStyle(headingFocused ? Theme.faint : .white))
                    .textInputAutocapitalization(.characters)
                    .caps(16)
                    .multilineTextAlignment(.center)
                    .focused($headingFocused)
                    .submitLabel(.done)
                    .padding(.vertical, 4)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(headingFocused ? Theme.indigo : Theme.faint)
                            .frame(height: headingFocused ? 1.5 : 1)
                            .mask(headingFocused ? AnyView(Rectangle()) : AnyView(DottedLine()))
                    }
                    .frame(maxWidth: 320)
                    .padding(.horizontal, Theme.gutter)
                    .accessibilityLabel("Event name")
            } else {
                Text(heading(item))
                    .caps(16)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.gutter)
            }
            Text("\(item.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()) · \(rangeLabel(span))")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.muted)
            if let value {
                if store.metric == .stress {
                    StressGauge(value: value, caption: durationLabel(span))
                        .padding(.top, 16)
                } else {
                    Text(store.metric.format(value))
                        .font(.number(72))
                        .contentTransition(.numericText())
                        .padding(.top, 4)
                    Text("AVG HEART RATE").caps(14, color: Theme.muted)
                }
            }
        }
    }

    /// The selected part of a block, scored on its own. Nil if the times aren't a valid span inside it.
    private func draftScore(_ block: ScoredItem) -> ScoredItem? {
        guard draft.blockId == block.id, draft.end > draft.start,
              draft.start >= block.start, draft.end <= block.end else { return nil }
        let input = TimelineInput(id: "draft", title: "", start: draft.start, end: draft.end, isBlock: true)
        let scored = Scoring.score(input, samples: store.samples(from: draft.start, to: draft.end + Scoring.carryover),
                                   baseline: block.baselineHr)
        return scored.hasData ? scored : nil
    }

    // MARK: Chart

    /// The hour around `item`, with `overlay` (the item, or the part of a block being named) highlighted.
    private func chart(_ item: ScoredItem, overlay: ScoredItem) -> some View {
        let from = item.start.addingTimeInterval(-3600), to = item.end.addingTimeInterval(3600)
        return StressChart(
            from: from, to: to,
            baseline: item.baselineHr,
            extent: item.isBlock ? (item.start, item.end) : nil,
            overlay: (overlay.start, overlay.end),
            // Drop the window's first time when the highlight starts close enough to collide with it.
            labels: overlay.start.timeIntervalSince(from) / to.timeIntervalSince(from) > 0.2
                ? [from, overlay.start, overlay.end] : [overlay.start, overlay.end]
        )
    }

    @ViewBuilder
    private func notes(_ item: ScoredItem) -> some View {
        if item.active {
            InsightCard(title: "Physical activity",
                        text: "Your heart rate rose from effort, not stress, so this is left out of stress labels.")
        } else if !item.isBlock, let carry = item.carryoverPct, carry > 0.08 {
            InsightCard(title: "Lingering stress",
                        text: "Your heart rate stayed \(pct(carry)) above baseline for 30 minutes after this ended.")
        }
    }

    // MARK: Statistics

    private func statistics(_ span: ScoredItem) -> some View {
        let day = store.items.filter { $0.hasData && !$0.active }
        let dayAvg = day.isEmpty ? span.stress : day.map(\.stress).reduce(0, +) / Double(day.count)
        return StatGroup(footer: "\(span.isBlock ? "This stretch" : "This event") vs. your day and resting baseline") {
            Button { store.metric = .stress } label: {
                StatRow(icon: "waveform.path.ecg", label: "STRESS", value: String(format: "%.1f", span.stress),
                        trend: Trend((span.stress - dayAvg) / 3, eps: 0.02), selected: store.metric == .stress)
            }
            Button { store.metric = .hr } label: {
                StatRow(icon: "heart", label: "AVG HEART RATE", value: "\(Int(span.avgHr.rounded()))", unit: "bpm",
                        trend: Trend(span.deltaPct), selected: store.metric == .hr)
            }
            StatRow(icon: "bolt.heart", label: "PEAK HEART RATE", value: "\(Int(span.peakHr.rounded()))", unit: "bpm",
                    trend: Trend((span.peakHr - span.baselineHr) / span.baselineHr))
            StatRow(icon: "chart.line.uptrend.xyaxis", label: "VS. BASELINE", value: pct(span.deltaPct), trend: Trend(span.deltaPct))
        }
        .buttonStyle(.plain)
    }

    // MARK: Similar events

    /// Summary row (count, average stress and mood) that expands to the list.
    @ViewBuilder
    private func similar(_ item: ScoredItem) -> some View {
        let xs = store.similarEvents(to: item)
        if !xs.isEmpty {
            let avgStress = xs.map(\.stress).reduce(0, +) / Double(xs.count)
            let moods = xs.compactMap { store.feelings[$0.id] }.map(Double.init)
            let avgMood = moods.isEmpty ? nil : moods.reduce(0, +) / Double(moods.count)
            VStack(spacing: 14) {
                SectionHeader(title: "SIMILAR EVENTS")
                VStack(spacing: 8) {
                    Button {
                        withAnimation(.spring(response: 0.42, dampingFraction: 0.72)) { similarOpen.toggle() }
                    } label: {
                        HStack(spacing: 16) {
                            Text("\(xs.count) event\(xs.count == 1 ? "" : "s")").font(.system(size: 13, weight: .semibold))
                            Spacer()
                            average("AVG STRESS", String(format: "%.1f", avgStress), StressLevel(avgStress).color)
                            if let avgMood { average("AVG MOOD", String(format: "%+.1f", avgMood), .white) }
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(Theme.muted)
                                .rotationEffect(.degrees(similarOpen ? 180 : 0))
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 56)
                        .card()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(similarOpen ? "Hides the list" : "Shows each similar event")

                    if similarOpen {
                        VStack(spacing: 0) {
                            ForEach(Array(xs.enumerated()), id: \.element.id) { i, x in
                                if i > 0 { Rectangle().fill(Theme.cardLine).frame(height: 1) }
                                Button { withAnimation(.snappy) { selectedId = x.id } } label: {
                                    HStack(spacing: 10) {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(x.title.uppercased()).caps(11).lineLimit(1)
                                            Text("\(x.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(x.start.formatted(date: .omitted, time: .shortened))")
                                                .font(.system(size: 12)).foregroundStyle(Theme.muted)
                                        }
                                        Spacer()
                                        Text(String(format: "%.1f", x.stress)).font(.number(17)).foregroundStyle(StressLevel(x.stress).color)
                                    }
                                    .frame(minHeight: 52)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 4)
                        .card(radius: 12)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96, anchor: .top)).combined(with: .offset(y: -6)),
                            removal: .opacity))
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
        }
    }

    private func average(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).caps(8, color: Theme.muted)
            Text(value).font(.number(20)).foregroundStyle(color)
        }
    }

    // MARK: Feelings

    private func feelings(_ item: ScoredItem) -> some View {
        let current = store.feelings[item.id].flatMap(Feeling.init)
        return VStack(spacing: 14) {
            SectionHeader(title: "HOW DID IT FEEL?")
            HStack(spacing: 6) {
                ForEach(Feeling.allCases) { f in
                    Button {
                        store.setFeeling(current == f ? nil : f, for: item.id)
                    } label: {
                        VStack(spacing: 8) {
                            Circle().fill(f.color).frame(width: 12, height: 12)
                            Text(f.label).caps(9, color: current == f ? .white : Theme.muted)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .card(current == f ? Theme.cardRaised : Theme.card, radius: 12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(current == f ? f.color : .clear, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(current == f ? .isSelected : [])
                }
            }
            .padding(.horizontal, Theme.gutter)
        }
    }
}

/// Name part (or all) of an unscheduled stretch to turn it into an event.
struct AddEventForm: View {
    @Environment(AppStore.self) private var store
    let block: ScoredItem
    @Binding var draft: EventSheet.Draft
    @Binding var selectedId: String?

    @State private var toCalendar = true
    @State private var error: String?
    @FocusState private var titleFocused: Bool

    private var trimmedTitle: String { draft.title.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 10) {
            SectionHeader(title: "ADD AN EVENT") { Text(durationLabel(block).uppercased()).caps(12, color: Theme.muted) }
                .padding(.bottom, 4)
            TextField("", text: $draft.title, prompt: Text("What were you doing?").foregroundStyle(Theme.faint))
                .font(.system(size: 16, weight: .medium))
                .focused($titleFocused)
                .submitLabel(.done)
                .padding(.horizontal, 16)
                .frame(minHeight: 52)
                .card()
                .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(titleFocused ? Theme.indigo : .clear, lineWidth: 1))
                .padding(.horizontal, Theme.gutter)

            StatGroup {
                timeRow("FROM", "clock", $draft.start)
                timeRow("TO", "clock.badge.checkmark", $draft.end)
                if store.canAddToCalendar {
                    Toggle(isOn: $toCalendar) { Text("ALSO ADD TO CALENDAR").caps(11) }
                        .tint(Theme.indigo)
                        .frame(minHeight: 52)
                }
            }
            Group {
                if let error {
                    Text(error).font(.system(size: 13)).foregroundStyle(Theme.red)
                }
                Button { add() } label: {
                    Text("ADD EVENT")
                        .caps(12, weight: .heavy, color: .black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 12).fill(.white))
                }
                .buttonStyle(.plain)
                .disabled(trimmedTitle.isEmpty)
                .opacity(trimmedTitle.isEmpty ? 0.5 : 1)
                .padding(.top, 6)
            }
            .padding(.horizontal, Theme.gutter)
        }
    }

    private func timeRow(_ label: String, _ icon: String, _ value: Binding<Date>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.muted).frame(width: 20)
            Text(label).caps(11)
            Spacer()
            DatePicker(label, selection: value, in: block.start...block.end, displayedComponents: .hourAndMinute)
                .labelsHidden()
        }
        .frame(minHeight: 56)
    }

    private func add() {
        guard draft.end > draft.start else { error = "End time needs to be after the start time."; return }
        do {
            let id = try store.addEvent(
                title: trimmedTitle,
                start: draft.start, end: draft.end,
                toCalendar: store.canAddToCalendar && toCalendar
            )
            selectedId = id
        } catch {
            self.error = error.localizedDescription
        }
    }
}

func pct(_ v: Double) -> String { "\(v >= 0 ? "+" : "")\(Int((v * 100).rounded()))%" }
