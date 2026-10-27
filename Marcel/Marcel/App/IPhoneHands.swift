import Contacts
import CoreLocation
import EventKit

/// The iPhone as the bots' hands, like Grok Bot's local tools: a bot asks (an ```iphone``` block),
/// the user's rules decide, and the app reads the reminders, contacts, location or calendar here, or
/// adds a reminder, then sends back what it found as the next message. Nothing of the iPhone leaves it
/// unless a bot asked for it and the rules let it.
nonisolated enum IPhoneHands {
    struct Request: Decodable, Sendable {
        struct Reminder: Decodable, Sendable {
            let titre: String
            let quand: String?
        }

        let lire: String?
        let chercher: String?
        let jours: Int?
        let ajouterRappel: Reminder?

        enum CodingKeys: String, CodingKey {
            case lire, chercher, jours
            case ajouterRappel = "ajouter_rappel"
        }
    }

    /// What was done, said in one line for the card, and the text sent back to the bot.
    struct Result: Sendable {
        let summary: String
        let text: String
    }

    private static let maxReminders = 30
    private static let maxContacts = 5

    static func run(_ query: String) async -> Result {
        guard let data = query.data(using: .utf8),
              let request = try? JSONDecoder().decode(Request.self, from: data) else {
            return Result(summary: "Demande illisible", text: "Demande à l'iPhone illisible : rien n'a été lu.")
        }
        if let reminder = request.ajouterRappel {
            return await addReminder(reminder)
        }
        switch request.lire {
        case "rappels": return await reminders()
        case "contacts": return await contacts(named: request.chercher ?? "")
        case "position": return await location()
        case "agenda": return await agenda(days: request.jours ?? 7)
        default: return Result(summary: "Demande inconnue", text: "L'iPhone ne sait pas faire ça.")
        }
    }

    // MARK: Reminders

    // EventKit's store may be used from any thread.
    private nonisolated(unsafe) static let events = EKEventStore()

    private static func remindersAllowed() async -> Bool {
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { return true }
        return (try? await events.requestFullAccessToReminders()) ?? false
    }

    private static func reminders() async -> Result {
        guard await remindersAllowed() else { return refused("aux rappels") }
        let predicate = events.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        // EventKit answers on its own thread: the reminders become lines there.
        let lines: [String] = await withCheckedContinuation { continuation in
            events.fetchReminders(matching: predicate) { found in
                let sorted = (found ?? []).sorted {
                    ($0.dueDateComponents?.date ?? .distantFuture) < ($1.dueDateComponents?.date ?? .distantFuture)
                }
                continuation.resume(returning: sorted.prefix(maxReminders).map { reminder in
                    let due = reminder.dueDateComponents?.date
                        .map { " (pour le " + $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()) + ")" } ?? ""
                    return "- \(reminder.title ?? "Sans titre")\(due)"
                })
            }
        }
        guard !lines.isEmpty else { return Result(summary: "Aucun rappel en cours", text: "Rappels de l'iPhone : aucun en cours.") }
        return Result(summary: "\(lines.count) rappel(s) lu(s)", text: "Rappels en cours sur l'iPhone :\n" + lines.joined(separator: "\n"))
    }

    private static func addReminder(_ asked: Request.Reminder) async -> Result {
        guard await remindersAllowed(), let list = events.defaultCalendarForNewReminders() else {
            return refused("aux rappels")
        }
        let reminder = EKReminder(eventStore: events)
        reminder.title = asked.titre
        reminder.calendar = list
        var when = ""
        if let raw = asked.quand, let date = parseDate(raw) {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            reminder.addAlarm(EKAlarm(absoluteDate: date))
            when = " pour le " + date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
        }
        do {
            try events.save(reminder, commit: true)
        } catch {
            return Result(summary: "Rappel pas ajouté", text: "Le rappel n'a pas pu être ajouté : \(error.localizedDescription)")
        }
        return Result(summary: "Rappel ajouté\(when)", text: "Rappel « \(asked.titre) » ajouté sur l'iPhone\(when).")
    }

    /// "2026-10-28T09:00" (the user's time), with or without seconds or zone.
    private static func parseDate(_ raw: String) -> Date? {
        if let date = try? Date(raw, strategy: .iso8601) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }

    // MARK: Contacts

    private static func contacts(named name: String) async -> Result {
        let store = CNContactStore()
        guard (try? await store.requestAccess(for: .contacts)) == true else { return refused("aux contacts") }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey] as [CNKeyDescriptor]
        let found = (try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name),
                                                keysToFetch: keys)) ?? []
        guard !found.isEmpty else {
            return Result(summary: "Personne trouvé", text: "Contacts de l'iPhone : personne ne s'appelle « \(name) ».")
        }
        let lines = found.prefix(maxContacts).map { contact in
            let fullName = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
            let phones = contact.phoneNumbers.map { $0.value.stringValue }
            let emails = contact.emailAddresses.map { $0.value as String }
            let company = contact.organizationName.isEmpty ? "" : " (\(contact.organizationName))"
            return "- \(fullName.isEmpty ? contact.organizationName : fullName)\(company) : "
                + (phones + emails).joined(separator: ", ")
        }
        return Result(summary: "\(lines.count) contact(s) lu(s)", text: "Contacts « \(name) » sur l'iPhone :\n" + lines.joined(separator: "\n"))
    }

    // MARK: Location

    private static func location() async -> Result {
        // Asks for "while using the app" if needed, then waits for one good fix.
        let session = CLServiceSession(authorization: .whenInUse)
        defer { session.invalidate() }
        var fix: CLLocation?
        do {
            for try await update in CLLocationUpdate.liveUpdates() {
                if update.authorizationDenied || update.authorizationDeniedGlobally { break }
                if let location = update.location, location.horizontalAccuracy < 200 {
                    fix = location
                    break
                }
            }
        } catch {
            fix = nil
        }
        guard let fix else { return refused("à la position") }
        let place = (try? await CLGeocoder().reverseGeocodeLocation(fix))?.first
        let address = [place?.name, place?.postalCode, place?.locality].compactMap { $0 }.joined(separator: ", ")
        let coordinates = String(format: "%.4f, %.4f", fix.coordinate.latitude, fix.coordinate.longitude)
        return Result(summary: address.isEmpty ? "Position lue" : address,
                      text: "Position de l'iPhone : \(address.isEmpty ? "" : address + " — ")\(coordinates)")
    }

    // MARK: Calendar

    private static func agenda(days: Int) async -> Result {
        guard await Agenda.requestAccess() else { return refused("à l'agenda") }
        let lines = await Agenda.events(days: days)
        guard !lines.isEmpty else {
            return Result(summary: "Rien de prévu", text: "Agenda de l'iPhone : rien de prévu les \(days) prochains jours.")
        }
        return Result(summary: "\(lines.count) événement(s) lu(s)",
                      text: "Agenda de l'iPhone, \(days) prochains jours :\n" + lines.joined(separator: "\n"))
    }

    private static func refused(_ what: String) -> Result {
        Result(summary: "Accès refusé par iOS",
               text: "L'iPhone n'a pas l'accès \(what) (Réglages iOS › Marcel) : rien n'a été lu.")
    }
}
