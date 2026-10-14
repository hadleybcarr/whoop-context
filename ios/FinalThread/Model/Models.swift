import SwiftUI

/// One minute-level WHOOP reading. `stress` is filled in from heart rate when the source has none.
struct Sample {
    let t: Date
    let bpm: Double
    var stress: Double?
}

struct SleepWindow {
    let wake: Date
    let bed: Date
}

struct CalendarEvent: Identifiable, Codable {
    var id: String
    var title: String
    var start: Date
    var end: Date
    var attendees = 0
    var recurring = false
    /// Added in the app from unscheduled time and kept locally (not in a calendar).
    var custom = false
}

enum Metric: String, CaseIterable, Identifiable {
    case stress, hr

    var id: String { rawValue }
    var label: String { self == .stress ? "Stress" : "Heart Rate" }
    var unit: String { self == .stress ? "0–3" : "bpm" }

    func format(_ v: Double) -> String {
        self == .stress ? String(format: "%.1f", v) : "\(Int(v.rounded()))"
    }
}

/// Minutes in each Stress Monitor band.
struct StressBreakdown {
    var low = 0.0
    var medium = 0.0
    var high = 0.0
    var total: Double { low + medium + high }
}

struct MetricValue {
    let value: Double
    let peak: Double
    /// 0...1, bar length.
    let fraction: Double
}

/// A calendar event or an unscheduled block, scored against the day's heart rate.
struct ScoredItem: Identifiable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isBlock: Bool
    let isCustom: Bool
    let active: Bool
    var attendees = 0
    var recurring = false

    var hasData = false
    var metrics: [Metric: MetricValue] = [:]
    var avgHr = 0.0
    var peakHr = 0.0
    var baselineHr = 0.0
    var deltaPct = 0.0
    var carryoverPct: Double?

    var stress: Double { metrics[.stress]?.value ?? 0 }
}

enum Feeling: Int, CaseIterable, Identifiable {
    case drained = -2, tense, neutral, good, great

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .drained: "DRAINED"
        case .tense: "TENSE"
        case .neutral: "NEUTRAL"
        case .good: "GOOD"
        case .great: "GREAT"
        }
    }

    var color: Color {
        switch self {
        case .drained: Theme.red
        case .tense: Theme.yellow
        case .neutral: Theme.muted
        case .good: Color(hex: 0x8AF27F)
        case .great: Theme.green
        }
    }
}
