import Foundation
import Observation

@Observable
final class AppStore {
    static let historyDays = 21
    /// Used when there's no sleep data for a day.
    static let defaultWakeMinutes = 7 * 60
    static let defaultBedMinutes = 23 * 60

    private(set) var events: [CalendarEvent]
    private(set) var customEvents: [CalendarEvent]
    private(set) var samples: [Sample]
    private(set) var sleep: [String: SleepWindow]
    private(set) var feelings: [String: Int]
    private(set) var scoredByDay: [String: [ScoredItem]] = [:]
    private(set) var calendarSource = "Demo calendar"
    private(set) var healthSource = "demo heart rate"
    private(set) var calendarConnected = false

    var metric: Metric {
        didSet { UserDefaults.standard.set(metric.rawValue, forKey: Keys.metric) }
    }
    var dayOffset = 0
    var now = Date()

    private let calendar = CalendarService()
    private let health = HealthService()

    private enum Keys {
        static let feelings = "feelings"
        static let custom = "customEvents"
        static let metric = "metric"
    }

    init() {
        let demo = DemoData.generate(endDay: .now, days: Self.historyDays)
        events = demo.events
        samples = demo.samples
        sleep = demo.sleep
        let saved = UserDefaults.standard.dictionary(forKey: Keys.feelings) as? [String: Int] ?? [:]
        feelings = demo.feelings.merging(saved) { _, new in new }
        customEvents = (UserDefaults.standard.data(forKey: Keys.custom))
            .flatMap { try? JSONDecoder().decode([CalendarEvent].self, from: $0) } ?? []
        metric = Metric(rawValue: UserDefaults.standard.string(forKey: Keys.metric) ?? "") ?? .stress
        rescore()
    }

    // MARK: Days

    var today: Date { Calendar.current.startOfDay(for: now) }

    var currentDay: Date { Calendar.current.date(byAdding: .day, value: -dayOffset, to: today)! }

    var items: [ScoredItem] { scoredByDay[Scoring.dayKey(currentDay)] ?? [] }

    var dayLabel: String {
        switch dayOffset {
        case 0: "TODAY"
        case 1: "YESTERDAY"
        default: currentDay.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
        }
    }

    // MARK: Scoring

    /// Scores calendar events plus the unscheduled blocks between them, wake-up to usual bedtime.
    func rescore() {
        let all = (events + customEvents).map(TimelineInput.init)
        let bedMin = Scoring.typicalBedMinutes(sleep) ?? Self.defaultBedMinutes
        let cal = Calendar.current
        var result: [String: [ScoredItem]] = [:]

        for i in 0..<Self.historyDays {
            let day = cal.date(byAdding: .day, value: -i, to: today)!
            let key = Scoring.dayKey(day)
            let next = cal.date(byAdding: .day, value: 1, to: day)!
            let dayEvents = all.filter { $0.start >= day && $0.start < next }

            // Per-day baseline, and minute-level stress where the source didn't provide it.
            let range = samples.indices.filter { samples[$0].t >= day && samples[$0].t < next }
            let baseline = Scoring.dayBaseline(range.map { samples[$0] }, day: day)
            if let baseline {
                for j in range where samples[j].stress == nil {
                    samples[j].stress = Scoring.minuteStress(samples[j].bpm, baseline: baseline)
                }
            }
            let daySamples = range.map { samples[$0] }

            let blocks = Scoring.buildBlocks(
                events: dayEvents,
                wake: sleep[key]?.wake ?? Scoring.minutes(day, Self.defaultWakeMinutes),
                bedtime: Scoring.minutes(day, bedMin),
                until: i == 0 ? now : nil
            )
            result[key] = (dayEvents + blocks)
                .map { Scoring.score($0, samples: daySamples, baseline: baseline) }
                .sorted { ($0.start, $0.isBlock ? 1 : 0) < ($1.start, $1.isBlock ? 1 : 0) }
        }
        scoredByDay = result
    }

    /// Called every minute so the "now" marker and today's blocks stay current.
    func tick() {
        now = Date()
        if dayOffset == 0 { rescore() }
    }

    /// Minutes spent in each Stress Monitor band on `day`. Each reading counts until the next
    /// one, up to 5 minutes, so gaps in wear don't count.
    func stressBreakdown(for day: Date) -> StressBreakdown {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let daySamples = samples.filter { $0.t >= day && $0.t < next }
        var out = StressBreakdown()
        for (s, following) in zip(daySamples, daySamples.dropFirst()) {
            guard let stress = s.stress else { continue }
            let minutes = min(following.t.timeIntervalSince(s.t), 300) / 60
            switch StressLevel(stress) {
            case .low: out.low += minutes
            case .medium: out.medium += minutes
            case .high: out.high += minutes
            }
        }
        return out
    }

    /// Average breakdown over the other days in history that fall on the same weekday.
    func typicalBreakdown(like day: Date) -> StressBreakdown? {
        let cal = Calendar.current
        let weekday = cal.component(.weekday, from: day)
        let others = (1..<Self.historyDays)
            .map { cal.date(byAdding: .day, value: -$0, to: today)! }
            .filter { cal.component(.weekday, from: $0) == weekday && $0 != day }
            .map(stressBreakdown(for:))
            .filter { $0.total > 0 }
        guard !others.isEmpty else { return nil }
        let n = Double(others.count)
        return StressBreakdown(
            low: others.map(\.low).reduce(0, +) / n,
            medium: others.map(\.medium).reduce(0, +) / n,
            high: others.map(\.high).reduce(0, +) / n
        )
    }

    /// Longest unbroken run of high-stress readings on `day` (gaps over 5 minutes end a run).
    /// Workouts are skipped: a high heart rate there is effort, not stress.
    func longestHighStretch(on day: Date) -> (start: Date, minutes: Int)? {
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let workouts = (scoredByDay[Scoring.dayKey(day)] ?? []).filter(\.active)
        let xs = samples.filter { s in
            s.t >= day && s.t < next && s.stress != nil && !workouts.contains { s.t >= $0.start && s.t < $0.end }
        }
        var best: (start: Date, end: Date)?
        var run: (start: Date, end: Date)?
        for (i, s) in xs.enumerated() {
            let high = StressLevel(s.stress!) == .high
            if high, let r = run, s.t.timeIntervalSince(xs[i - 1].t) <= 300 {
                run = (r.start, s.t)
            } else {
                run = high ? (s.t, s.t) : nil
            }
            if let r = run, best == nil || r.end.timeIntervalSince(r.start) > best!.end.timeIntervalSince(best!.start) {
                best = r
            }
        }
        return best.map { ($0.start, max(1, Int(($0.end.timeIntervalSince($0.start) / 60).rounded()) + 2)) }
    }

    /// Words that don't make two titles "similar".
    private static let stopWords: Set<String> = ["with", "the", "and", "for", "from", "to", "of", "a", "an", "at", "on", "in", "my", "our", "call", "meeting"]

    private static func titleWords(_ title: String) -> Set<String> {
        Set(title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) })
    }

    /// Other events whose titles share a meaningful word with this one (same title included), newest first.
    func similarEvents(to item: ScoredItem, limit: Int = 30) -> [ScoredItem] {
        let words = Self.titleWords(item.title)
        guard !words.isEmpty else { return [] }
        return scoredByDay.values.flatMap { $0 }
            .filter { !$0.isBlock && $0.hasData && $0.id != item.id && !Self.titleWords($0.title).isDisjoint(with: words) }
            .sorted { $0.start > $1.start }
            .prefix(limit)
            .map { $0 }
    }

    /// The most recent unscheduled stretch on the current day that has data — what "+" opens.
    var latestBlock: ScoredItem? { items.last { $0.isBlock && $0.hasData } }

    func samples(from start: Date, to end: Date) -> [Sample] {
        samples.filter { $0.t >= start && $0.t <= end }
    }

    func item(id: String) -> ScoredItem? {
        scoredByDay.values.lazy.flatMap { $0 }.first { $0.id == id }
    }

    // MARK: Feelings

    func setFeeling(_ feeling: Feeling?, for id: String) {
        feelings[id] = feeling?.rawValue
        UserDefaults.standard.set(feelings, forKey: Keys.feelings)
    }

    // MARK: Adding events from unscheduled time

    var canAddToCalendar: Bool { calendarConnected }

    @discardableResult
    func addEvent(title: String, start: Date, end: Date, toCalendar: Bool) throws -> String {
        let event: CalendarEvent
        if toCalendar {
            event = try calendar.add(title: title, start: start, end: end)
            events.append(event)
        } else {
            event = CalendarEvent(id: "custom-\(UUID().uuidString)", title: title, start: start, end: end, custom: true)
            customEvents.append(event)
            saveCustomEvents()
        }
        rescore()
        return event.id
    }

    func removeCustomEvent(id: String) {
        customEvents.removeAll { $0.id == id }
        setFeeling(nil, for: id)
        saveCustomEvents()
        rescore()
    }

    private func saveCustomEvents() {
        UserDefaults.standard.set(try? JSONEncoder().encode(customEvents), forKey: Keys.custom)
    }

    // MARK: Data sources

    private var historyStart: Date { Calendar.current.date(byAdding: .day, value: -(Self.historyDays - 1), to: today)! }

    func connectCalendar() async throws {
        guard try await calendar.requestAccess() else { throw SourceError.denied("Calendar") }
        let end = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        events = calendar.events(from: historyStart, to: end)
        calendarConnected = true
        calendarSource = "iPhone Calendar"
        if healthSource == "demo heart rate" {
            // Demo heart rate and sleep against real events would invent results, so drop them.
            samples = []
            sleep = [:]
            healthSource = "no heart rate yet"
        }
        rescore()
    }

    func connectHealth() async throws {
        guard HealthService.isAvailable else { throw SourceError.unavailable }
        try await health.requestAccess()
        let fetched = try await health.heartRate(from: historyStart, to: now)
        guard !fetched.isEmpty else { throw SourceError.noData }
        samples = fetched
        sleep = (try? await health.sleepWindows(from: historyStart.addingTimeInterval(-86400), to: now)) ?? [:]
        healthSource = "Apple Health (\(fetched.count.formatted()) readings)"
        rescore()
    }

    var sourceLabel: String { "\(calendarSource) · \(healthSource)" }

    var exportCSV: String {
        Scoring.csv(scoredByDay.values.flatMap { $0 }.sorted { $0.start < $1.start }, feelings: feelings)
    }

    enum SourceError: LocalizedError {
        case denied(String), unavailable, noData
        var errorDescription: String? {
            switch self {
            case .denied(let what): "\(what) access was not allowed. You can turn it on in Settings."
            case .unavailable: "Apple Health isn't available on this device."
            case .noData: "No heart rate found in Apple Health for the last 3 weeks."
            }
        }
    }
}
