import Foundation

/// Port of web/js/demo.js: a few weeks of calendar events, minute-level heart rate and sleep,
/// so the app works before Calendar and Apple Health are connected. Each template has a hidden
/// effect on HR (hr) and on how it felt (joy) for the ML model to recover.
enum DemoData {
    struct Template {
        let title: String
        let hour: Int, minute: Int, length: Int
        let hr: Double, joy: Double
        /// 0 = Sunday, like JavaScript's getDay().
        let days: [Int]
        var attendees = 0
        var recurring = false
        var once: Int?
    }

    static let templates: [Template] = [
        Template(title: "Morning Activity", hour: 7, minute: 0, length: 45, hr: 0.55, joy: 1.2, days: [1, 3, 5, 6]),
        Template(title: "Team Standup", hour: 9, minute: 30, length: 15, hr: 0.08, joy: 0, days: [1, 2, 3, 4, 5], attendees: 6, recurring: true),
        Template(title: "Deep Work Block", hour: 10, minute: 0, length: 90, hr: 0.02, joy: 0.6, days: [1, 2, 4]),
        Template(title: "Organic Chemistry Lecture", hour: 11, minute: 0, length: 80, hr: 0.12, joy: -0.6, days: [2, 4], recurring: true),
        Template(title: "Lunch with Sam", hour: 12, minute: 30, length: 60, hr: 0.06, joy: 1.6, days: [3], attendees: 2),
        Template(title: "1:1 with Manager", hour: 14, minute: 0, length: 30, hr: 0.22, joy: -0.4, days: [2], attendees: 2, recurring: true),
        Template(title: "Exam Review Session", hour: 15, minute: 0, length: 90, hr: 0.27, joy: -1.3, days: [4]),
        Template(title: "Design Critique", hour: 16, minute: 0, length: 60, hr: 0.2, joy: -0.2, days: [1, 3], attendees: 8),
        Template(title: "Investor Pitch Practice", hour: 13, minute: 0, length: 45, hr: 0.32, joy: -0.8, days: [5], attendees: 4),
        Template(title: "Coffee with Friends", hour: 16, minute: 30, length: 45, hr: 0.03, joy: 1.5, days: [5, 6], attendees: 3),
        Template(title: "Dentist Appointment", hour: 10, minute: 0, length: 45, hr: 0.18, joy: -1.0, days: [6], once: 3),
        Template(title: "Family Call", hour: 19, minute: 0, length: 30, hr: -0.02, joy: 1.1, days: [0]),
        Template(title: "Yoga", hour: 18, minute: 0, length: 60, hr: 0.3, joy: 1.3, days: [0, 2]),
        Template(title: "Budget Review", hour: 15, minute: 30, length: 45, hr: 0.19, joy: -1.1, days: [3], attendees: 3),
        Template(title: "Office Hours", hour: 17, minute: 0, length: 60, hr: 0.1, joy: 0.2, days: [1, 4]),
    ]

    /// mulberry32, bit-for-bit with the JavaScript version.
    struct Random {
        var state: UInt32
        mutating func next() -> Double {
            state = state &+ 0x6D2B79F5
            var t = (state ^ (state >> 15)) &* (1 | state)
            t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
        mutating func gauss() -> Double {
            let u = max(next(), 1e-9)
            return sqrt(-2 * log(u)) * cos(2 * .pi * next())
        }
    }

    struct Output {
        var events: [CalendarEvent] = []
        var samples: [Sample] = []
        var feelings: [String: Int] = [:]
        var sleep: [String: SleepWindow] = [:]
    }

    static func generate(endDay: Date, days: Int, seed: UInt32 = 7, now: Date = .now) -> Output {
        let cal = Calendar.current
        var rand = Random(state: seed)
        var out = Output()

        for i in stride(from: days - 1, through: 0, by: -1) {
            let day = cal.date(byAdding: .day, value: -i, to: cal.startOfDay(for: endDay))!
            let dow = cal.component(.weekday, from: day) - 1
            let at = { (m: Int) in Scoring.minutes(day, m) }

            let restHr = 60 + rand.gauss() * 2
            let wakeMin = 6 * 60 + 15 + Int((rand.next() * 60).rounded())
            let bedMin = 22 * 60 + 15 + Int((rand.next() * 80).rounded())
            let key = Scoring.dayKey(day)
            out.sleep[key] = SleepWindow(wake: at(wakeMin), bed: at(bedMin))

            // Off-calendar stress (commute, errands) for the unscheduled blocks to catch.
            let episodeCount = 1 + Int(rand.next() * 2)
            let episodes = (0..<episodeCount).map { _ -> (from: Int, to: Int, hr: Double) in
                let start = wakeMin + 60 + Int(rand.next() * Double(bedMin - wakeMin - 180))
                return (start, start + 30 + Int(rand.next() * 40), 0.12 + rand.next() * 0.18)
            }

            var todays: [(event: CalendarEvent, hr: Double)] = []
            for t in templates where t.days.contains(dow) && (t.once == nil || i % 7 == t.once) {
                guard rand.next() > 0.1 else { continue }
                let jitter = Int((rand.gauss() * 5).rounded())
                let start = at(t.hour * 60 + t.minute + jitter)
                let slug = t.title.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
                let event = CalendarEvent(
                    id: "demo-\(key)-\(slug)", title: t.title, start: start,
                    end: start.addingTimeInterval(Double(t.length) * 60),
                    attendees: t.attendees, recurring: t.recurring
                )
                let hr = t.hr + rand.gauss() * 0.04
                // Leave ~25% of past events unrated, like real users would.
                if i > 0 && rand.next() > 0.25 {
                    out.feelings[event.id] = max(-2, min(2, Int((t.joy + rand.gauss() * 0.6).rounded())))
                }
                todays.append((event, hr))
            }
            todays.sort { $0.event.start < $1.event.start }

            // Minute-level HR from wake-up to bedtime, every 2 minutes.
            var drift = 0.0
            for m in stride(from: wakeMin, to: bedMin, by: 2) {
                let t = at(m)
                if t > now { break }
                let circadian = 4 * sin((Double(m) / 60 - 9) / 24 * 2 * .pi)
                drift = drift * 0.9 + rand.gauss() * 0.8
                var effect = 0.0
                var inEvent = false
                for ep in episodes where m >= ep.from && m < ep.to { effect = max(effect, ep.hr) }
                for (e, hr) in todays {
                    if t >= e.start && t < e.end { effect = max(effect, hr); inEvent = true }
                    // Stressful events linger for a while after they end.
                    let sinceEnd = t.timeIntervalSince(e.end) / 60
                    if sinceEnd >= 0 && sinceEnd < 40 && hr > 0 { effect = max(effect, hr * 0.5 * (1 - sinceEnd / 40)) }
                }
                let bpm = restHr * (1 + effect) + circadian + drift + rand.gauss() * 2
                // Between events you walk now and then; in meetings you mostly sit.
                let walking = !inEvent && rand.next() < 0.12
                out.samples.append(Sample(t: t, bpm: (bpm + (walking ? 12 : 0)).rounded()))
            }
            out.events += todays.map(\.event)
        }
        return out
    }
}
