import HealthKit

/// Heart rate and sleep from Apple Health, where WHOOP writes them when its Health sync is on.
/// WHOOP's own API only offers daily summaries, so this is the route to minute-level data.
final class HealthService {
    private let store = HKHealthStore()
    private let heartRate = HKQuantityType(.heartRate)
    private let sleep = HKCategoryType(.sleepAnalysis)

    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    func requestAccess() async throws {
        try await store.requestAuthorization(toShare: [], read: [heartRate, sleep])
    }

    func heartRate(from start: Date, to end: Date) async throws -> [Sample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: heartRate, predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let bpm = HKUnit.count().unitDivided(by: .minute())
        return try await descriptor.result(for: store).map {
            Sample(t: $0.startDate, bpm: $0.quantity.doubleValue(for: bpm))
        }
    }

    /// Wake and bed times per day: wake is the end of the night's sleep that finishes on that
    /// morning; bed is the start of the sleep that begins that evening.
    func sleepWindows(from start: Date, to end: Date) async throws -> [String: SleepWindow] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: sleep, predicate: HKQuery.predicateForSamples(withStart: start, end: end))],
            sortDescriptors: [SortDescriptor(\.startDate)]
        )
        let asleep = try await descriptor.result(for: store).filter {
            HKCategoryValueSleepAnalysis.allAsleepValues.contains(HKCategoryValueSleepAnalysis(rawValue: $0.value)!)
        }
        let cal = Calendar.current
        var wakes: [String: Date] = [:], beds: [String: Date] = [:]
        for s in asleep {
            let endHour = cal.component(.hour, from: s.endDate)
            if (3..<13).contains(endHour) {
                let key = Scoring.dayKey(s.endDate)
                wakes[key] = max(wakes[key] ?? .distantPast, s.endDate)
            }
            let startHour = cal.component(.hour, from: s.startDate)
            if startHour >= 19 || startHour < 3 {
                // Sleep that starts after midnight belongs to the previous evening.
                let evening = startHour < 3 ? cal.date(byAdding: .day, value: -1, to: s.startDate)! : s.startDate
                let key = Scoring.dayKey(evening)
                beds[key] = min(beds[key] ?? .distantFuture, s.startDate)
            }
        }
        // Today has a wake time but no bedtime yet; 11pm stands in until it does.
        return wakes.reduce(into: [:]) { out, pair in
            out[pair.key] = SleepWindow(wake: pair.value, bed: beds[pair.key] ?? Scoring.minutes(pair.value, 23 * 60))
        }
    }
}
