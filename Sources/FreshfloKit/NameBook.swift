import Contacts
import EventKit
import Foundation

/// Names of the people you write to and meet with, so "Priya Raghunathan" is spelled right the first time.
/// Read from Contacts and recent Calendar attendees (only after you ask, with macOS's permission prompt), kept on this Mac,
/// and used as spelling hints for transcription and cleanup. Calendar attendees come first: they're the people you
/// actually talk to.
enum NameBook {
    static let limit = 600

    struct Result {
        var names: [String]
        var fromContacts = 0
        var fromCalendar = 0
        var problem: String?
    }

    static func harvest() async -> Result {
        var ranked: [String: Int] = [:]
        var problem: String?
        var fromCalendar = 0, fromContacts = 0

        // Calendar: everyone you've met with in the last 90 days or will in the next 30, most frequent first.
        let events = EKEventStore()
        if (try? await events.requestFullAccessToEvents()) == true {
            let start = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
            let end = Calendar.current.date(byAdding: .day, value: 30, to: Date())!
            let found = events.events(matching: events.predicateForEvents(withStart: start, end: end, calendars: nil))
            for event in found {
                for attendee in event.attendees ?? [] {
                    guard let name = attendee.name, isName(name) else { continue }
                    ranked[clean(name), default: 0] += 10
                    fromCalendar += 1
                }
            }
        } else {
            problem = "Calendar access wasn't allowed"
        }

        // Contacts: everyone in your address book.
        let store = CNContactStore()
        if (try? await store.requestAccess(for: .contacts)) == true {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey] as [CNKeyDescriptor]
            try? store.enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                let full = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                for name in [full, contact.nickname, contact.organizationName] where isName(name) {
                    ranked[clean(name), default: 0] += 1
                    fromContacts += 1
                }
            }
        } else {
            problem = problem.map { $0 + " and Contacts access wasn't allowed" } ?? "Contacts access wasn't allowed"
        }

        let names = ranked.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(limit).map(\.key)
        return Result(names: names, fromContacts: fromContacts, fromCalendar: fromCalendar, problem: names.isEmpty ? problem : nil)
    }

    /// Real names only: letters, a few words, not an email address or a room.
    static func isName(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count >= 2, t.count <= 40, !t.contains("@"), t.rangeOfCharacter(from: .decimalDigits) == nil else { return false }
        let words = t.split(separator: " ")
        guard (1...4).contains(words.count), t.first?.isUppercase == true || t.first?.isLetter == true else { return false }
        let lower = t.lowercased()
        return !["room", "conference", "meeting", "zoom", "calendar", "holiday", "unknown", "no reply", "noreply"].contains(where: lower.contains)
    }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
