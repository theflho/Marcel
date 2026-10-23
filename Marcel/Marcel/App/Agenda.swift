import EventKit

/// The iPhone's calendar, read only, shared with Marcel when the user turned it on:
/// the next seven days are sent with each message so Marcel can take them into account.
/// Nothing is ever written to the calendar.
enum Agenda {
    static let shareKey = "shareCalendar"
    private static let days = 7
    private static let maxEvents = 40
    private static let store = EKEventStore()

    static var isAuthorized: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Asks iOS for access (reading events needs "full access"; Marcel never writes).
    static func requestAccess() async -> Bool {
        if isAuthorized { return true }
        return await withCheckedContinuation { continuation in
            store.requestFullAccessToEvents { granted, _ in continuation.resume(returning: granted) }
        }
    }

    /// The coming days as short lines, or nil when sharing is off or not allowed.
    static func upcoming(now: Date = .now) -> String? {
        guard UserDefaults.standard.bool(forKey: shareKey), isAuthorized,
              let end = Calendar.current.date(byAdding: .day, value: days, to: now) else { return nil }
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: nil)
        // The missions calendar repeats the planning Marcel already has: left out.
        let missions = UserDefaults.standard.string(forKey: MissionCalendar.calendarKey)
        let events = store.events(matching: predicate)
            .filter { $0.calendar.calendarIdentifier != missions }
            .sorted { $0.startDate < $1.startDate }
            .prefix(maxEvents)
        let today = now.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute())
        guard !events.isEmpty else {
            return "Nous sommes le \(today). Agenda des \(days) prochains jours : rien de prévu."
        }
        let lines = events.map { event in
            let when = event.isAllDay
                ? event.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " (journée)"
                : event.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
            let place = event.location.map { " · \($0)" } ?? ""
            return "- \(when) : \(event.title ?? "Sans titre")\(place)"
        }
        return "Nous sommes le \(today). Agenda des \(days) prochains jours :\n" + lines.joined(separator: "\n")
    }
}
