import Foundation

/// Mirrors web/js/scoring.js so the app and the ML export agree.
enum Scoring {
    /// HR this far above baseline (as a fraction) is the top of the 0–3 stress scale,
    /// matching the range of WHOOP's Stress Monitor.
    static let stressFullScale = 0.4
    static let carryover: TimeInterval = 30 * 60
    /// Free time shorter than this isn't shown as an unscheduled block.
    static let minGap: TimeInterval = 15 * 60

    static let cal = Calendar.current

    // Titles that imply physical effort: their HR rise is exertion, not stress.
    private static let activeWords: Set<String> = [
        "run", "running", "gym", "lift", "lifting", "workout", "yoga", "swim", "ride", "cycling", "bike",
        "hike", "climb", "climbing", "soccer", "tennis", "basketball", "crossfit", "pilates", "spin",
    ]

    static func isActive(_ title: String) -> Bool {
        let lower = title.lowercased()
        if lower.contains("morning activity") { return true }
        return lower.split(whereSeparator: { !$0.isLetter }).contains { activeWords.contains(String($0)) }
    }

    // MARK: Dates

    static func minutes(_ day: Date, _ minutes: Int) -> Date {
        cal.date(byAdding: .minute, value: minutes, to: cal.startOfDay(for: day))!
    }

    static func floorHour(_ d: Date) -> Date { cal.dateInterval(of: .hour, for: d)!.start }

    static func ceilHour(_ d: Date) -> Date {
        let f = floorHour(d)
        return f < d ? f.addingTimeInterval(3600) : f
    }

    private static let keyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(_ d: Date) -> String { keyFormatter.string(from: d) }

    // MARK: Heart rate → stress

    static func percentile(_ sorted: [Double], _ p: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let i = min(sorted.count - 1, max(0, Int((p * Double(sorted.count - 1)).rounded())))
        return sorted[i]
    }

    /// Awake resting baseline: 10th percentile of the day's heart rate between 7am and 11pm.
    static func dayBaseline(_ samples: [Sample], day: Date) -> Double? {
        let from = minutes(day, 7 * 60), to = minutes(day, 23 * 60)
        return percentile(samples.filter { $0.t >= from && $0.t < to }.map(\.bpm).sorted(), 0.1)
    }

    static func minuteStress(_ bpm: Double, baseline: Double) -> Double {
        max(0, min(3, 3 * (bpm - baseline) / baseline / stressFullScale))
    }

    private static func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(xs.count) }
    private static func clamp01(_ x: Double) -> Double { max(0, min(1, x)) }

    static func score(_ input: TimelineInput, samples: [Sample], baseline: Double?) -> ScoredItem {
        var item = ScoredItem(
            id: input.id, title: input.title, start: input.start, end: input.end,
            isBlock: input.isBlock, isCustom: input.isCustom,
            active: !input.isBlock && isActive(input.title),
            attendees: input.attendees, recurring: input.recurring
        )
        let during = samples.filter { $0.t >= input.start && $0.t < input.end }
        guard let baseline, !during.isEmpty else { return item }

        let bpm = during.map(\.bpm)
        let avg = mean(bpm)
        item.hasData = true
        item.avgHr = avg
        item.peakHr = bpm.max()!
        item.baselineHr = baseline
        item.deltaPct = (avg - baseline) / baseline
        let after = samples.filter { $0.t >= input.end && $0.t < input.end + carryover }.map(\.bpm)
        item.carryoverPct = after.isEmpty ? nil : (mean(after) - baseline) / baseline

        item.metrics[.hr] = MetricValue(value: avg, peak: item.peakHr, fraction: clamp01(item.deltaPct / stressFullScale))
        let stress = during.compactMap(\.stress)
        if !stress.isEmpty {
            let s = mean(stress)
            item.metrics[.stress] = MetricValue(value: s, peak: stress.max()!, fraction: clamp01(s / 3))
        }
        return item
    }

    // MARK: Unscheduled time

    /// Calendar events take priority. Each stretch of free time between them, within the waking
    /// day (wake time rounded down to the hour → usual bedtime rounded up, at most 11:59pm),
    /// becomes one block.
    static func buildBlocks(events: [TimelineInput], wake: Date, bedtime: Date, until: Date?) -> [TimelineInput] {
        let dayStart = floorHour(wake)
        // Stop at 11:59pm so a block never ends on the next date (time pickers can't express that).
        let lastMinute = cal.date(bySettingHour: 23, minute: 59, second: 0, of: wake)!
        var dayEnd = min(ceilHour(bedtime), lastMinute)
        if let until, until < dayEnd { dayEnd = until }
        guard dayEnd > dayStart else { return [] }

        let busy = events
            .filter { $0.end > dayStart && $0.start < dayEnd }
            .sorted { $0.start < $1.start }

        var blocks: [TimelineInput] = []
        func add(_ s: Date, _ e: Date) {
            guard e.timeIntervalSince(s) >= minGap else { return }
            blocks.append(TimelineInput(id: "block-\(s.timeIntervalSince1970)", title: "", start: s, end: e, isBlock: true))
        }
        var cursor = dayStart
        for e in busy {
            if e.start > cursor { add(cursor, e.start) }
            if e.end > cursor { cursor = e.end }
        }
        if cursor < dayEnd { add(cursor, dayEnd) }
        return blocks
    }

    /// Usual bedtime in minutes after midnight (median). After-midnight bedtimes count as midnight.
    static func typicalBedMinutes(_ sleep: [String: SleepWindow]) -> Int? {
        let mins = sleep.values
            .map { cal.component(.hour, from: $0.bed) * 60 + cal.component(.minute, from: $0.bed) }
            .map { $0 < 4 * 60 ? 24 * 60 : $0 }
            .sorted()
        return mins.isEmpty ? nil : mins[mins.count / 2]
    }

    // MARK: Export

    static let csvColumns = [
        "event_id", "date", "start", "end", "start_hour", "weekday", "title", "duration_min", "attendees", "recurring",
        "active", "avg_hr", "peak_hr", "baseline_hr", "delta_pct", "carryover_pct", "stress", "feeling",
    ]

    /// Same format as the web page's "Export labels", for ml/train.py.
    static func csv(_ items: [ScoredItem], feelings: [String: Int]) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let esc = { (s: String) in "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        let f = { (v: Double?, d: Int) in v.map { String(format: "%.\(d)f", $0) } ?? "" }
        let rows = items.filter { $0.hasData && !$0.isBlock }.map { e -> String in
            let hour = Double(cal.component(.hour, from: e.start)) + Double(cal.component(.minute, from: e.start)) / 60
            return [
                esc(e.id), dayKey(e.start), iso.string(from: e.start), iso.string(from: e.end),
                String(format: "%.2f", hour), "\(cal.component(.weekday, from: e.start) - 1)", esc(e.title),
                "\(Int((e.end.timeIntervalSince(e.start) / 60).rounded()))", "\(e.attendees)", e.recurring ? "1" : "0",
                e.active ? "1" : "0", f(e.avgHr, 1), f(e.peakHr, 0), f(e.baselineHr, 1), f(e.deltaPct, 3),
                f(e.carryoverPct, 3), f(e.stress, 3), feelings[e.id].map(String.init) ?? "",
            ].joined(separator: ",")
        }
        return ([csvColumns.joined(separator: ",")] + rows).joined(separator: "\n")
    }
}

/// What gets scored: a calendar event or an unscheduled block.
struct TimelineInput {
    let id: String
    let title: String
    let start: Date
    let end: Date
    var isBlock = false
    var isCustom = false
    var attendees = 0
    var recurring = false

    init(id: String, title: String, start: Date, end: Date, isBlock: Bool = false) {
        self.id = id; self.title = title; self.start = start; self.end = end; self.isBlock = isBlock
    }

    init(_ e: CalendarEvent) {
        self.init(id: e.id, title: e.title, start: e.start, end: e.end)
        isCustom = e.custom
        attendees = e.attendees
        recurring = e.recurring
    }
}
