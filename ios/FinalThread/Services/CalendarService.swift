import EventKit

/// Reads and writes the iPhone's calendars through EventKit. That includes any Google
/// accounts added in Settings, so no separate Google sign-in is needed on iOS.
final class CalendarService {
    private let store = EKEventStore()

    var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    /// Timed events between `start` and `end`. All-day events are skipped: there's no time
    /// window to compare heart rate against.
    func events(from start: Date, to end: Date) -> [CalendarEvent] {
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .map { e in
                CalendarEvent(
                    id: e.calendarItemIdentifier + "-\(e.startDate.timeIntervalSince1970)",
                    title: e.title ?? "(No title)",
                    start: e.startDate,
                    end: e.endDate,
                    attendees: e.attendees?.count ?? 0,
                    recurring: e.hasRecurrenceRules
                )
            }
    }

    func add(title: String, start: Date, end: Date) throws -> CalendarEvent {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
        return CalendarEvent(
            id: event.calendarItemIdentifier + "-\(start.timeIntervalSince1970)",
            title: title, start: start, end: end
        )
    }
}
