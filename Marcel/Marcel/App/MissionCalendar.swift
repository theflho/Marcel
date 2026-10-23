import EventKit
import UIKit

/// Puts the RMA missions (planning read on the server) into the iPhone's calendar.
/// Marcel writes only in its own calendar, "Missions RMA": the user's other calendars are only
/// read, to skip a mission already entered by hand. A mission that moved is updated, one that
/// disappeared from the planning (cancelled) is removed, in the future and in that calendar only.
enum MissionCalendar {
    static let enabledKey = "missionCalendar"
    static let calendarKey = "missionCalendarID"
    static let lastSyncKey = "missionCalendarLastSync"
    private static let marker = "marcel-rma:"
    private static let store = EKEventStore()

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Turns it on (asking iOS for calendar access) or off. Returns whether it is on.
    /// Turning it off leaves the "Missions RMA" calendar as it is: the user may delete it.
    static func setEnabled(_ enabled: Bool) async -> Bool {
        let on = enabled ? await Agenda.requestAccess() : false
        UserDefaults.standard.set(on, forKey: enabledKey)
        return on
    }

    /// Brings the "Missions RMA" calendar in line with the planning; returns a short summary.
    @discardableResult
    static func sync(_ missions: [PlanningMission], now: Date = .now) -> String? {
        guard isEnabled, Agenda.isAuthorized, let calendar = missionsCalendar() else { return nil }
        let upcoming = missions.filter { $0.endAt > now }
        let horizon = upcoming.map(\.endAt).max() ?? now
        let events = store.events(matching: store.predicateForEvents(
            withStart: now.addingTimeInterval(-86_400), end: horizon.addingTimeInterval(86_400), calendars: nil))

        var ours: [String: EKEvent] = [:]
        for event in events where event.calendar.calendarIdentifier == calendar.calendarIdentifier {
            if let id = missionID(of: event) { ours[id] = event }
        }
        var added = 0, moved = 0, removed = 0
        for mission in upcoming {
            if let event = ours.removeValue(forKey: mission.id) {
                if event.startDate != mission.startAt || event.endDate != mission.endAt {
                    event.startDate = mission.startAt
                    event.endDate = mission.endAt
                    if (try? store.save(event, span: .thisEvent, commit: false)) != nil { moved += 1 }
                }
                continue
            }
            // Already in one of the user's calendars (entered by hand): left alone.
            if events.contains(where: { $0.calendar.calendarIdentifier != calendar.calendarIdentifier && matches($0, mission) }) {
                continue
            }
            let event = EKEvent(eventStore: store)
            event.calendar = calendar
            event.title = mission.store
            event.location = mission.store
            event.startDate = mission.startAt
            event.endDate = mission.endAt
            event.url = URL(string: WorkReminders.portalURL)
            event.notes = [mission.kind, mission.client, "Pointage sur place, dans le portail RMA.",
                           "\(marker)\(mission.id)"].filter { !$0.isEmpty }.joined(separator: "\n")
            if (try? store.save(event, span: .thisEvent, commit: false)) != nil { added += 1 }
        }
        // Left: future missions no longer in the planning, i.e. cancelled.
        for event in ours.values where event.startDate > now {
            if (try? store.remove(event, span: .thisEvent, commit: false)) != nil { removed += 1 }
        }
        try? store.commit()

        var parts: [String] = []
        if added > 0 { parts.append("\(added) ajoutée(s)") }
        if moved > 0 { parts.append("\(moved) déplacée(s)") }
        if removed > 0 { parts.append("\(removed) retirée(s)") }
        let summary = parts.isEmpty ? "à jour" : parts.joined(separator: ", ")
        UserDefaults.standard.set("\(summary), \(now.formatted(date: .abbreviated, time: .shortened))", forKey: lastSyncKey)
        return summary
    }

    /// Marcel's own calendar, created the first time (in iCloud when available).
    private static func missionsCalendar() -> EKCalendar? {
        if let id = UserDefaults.standard.string(forKey: calendarKey), let calendar = store.calendar(withIdentifier: id) {
            return calendar
        }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Missions RMA"
        calendar.cgColor = UIColor.systemOrange.cgColor
        guard let source = store.defaultCalendarForNewEvents?.source
                ?? store.sources.first(where: { $0.sourceType == .local }) else { return nil }
        calendar.source = source
        guard (try? store.saveCalendar(calendar, commit: true)) != nil else { return nil }
        UserDefaults.standard.set(calendar.calendarIdentifier, forKey: calendarKey)
        return calendar
    }

    private static func missionID(of event: EKEvent) -> String? {
        guard let notes = event.notes, let range = notes.range(of: marker) else { return nil }
        return String(notes[range.upperBound...].prefix { !$0.isWhitespace })
    }

    /// An event of another calendar that is this mission: starts within 15 minutes of it and
    /// mentions the store (its first word, e.g. "LECLERC") or the job.
    private static func matches(_ event: EKEvent, _ mission: PlanningMission) -> Bool {
        guard !event.isAllDay, abs(event.startDate.timeIntervalSince(mission.startAt)) <= 15 * 60 else { return false }
        let text = [event.title, event.location, event.notes].compactMap { $0 }.joined(separator: " ").uppercased()
        let storeWord = mission.store.split(separator: " ").first.map(String.init)?.uppercased() ?? ""
        return (storeWord.count >= 3 && text.contains(storeWord))
            || ["RMA", "FERRERO", "MISSION"].contains { text.contains($0) }
    }
}
