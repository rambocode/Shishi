import EventKit
import Foundation

/// All EventKit enumeration runs on one background queue; only value types cross back to UI.
final class EventKitIntegrationProvider: SystemIntegrationProvider, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Shishi.EventKit", qos: .userInitiated)
    private lazy var store = EKEventStore()
    func access(_ kind: IntegrationKind) -> IntegrationAccess {
        let status = EKEventStore.authorizationStatus(for: kind == .calendar ? .event : .reminder)
        if #available(macOS 14, *) {
            if status == .fullAccess { return .authorized }
            if status == .writeOnly { return .writeOnly }
        }
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .denied
        }
    }
    func request(_ kind: IntegrationKind) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                let completion: EKEventStoreRequestAccessCompletionHandler = { _, error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
                if #available(macOS 14, *) {
                    if kind == .calendar { self.store.requestFullAccessToEvents(completion: completion) }
                    else { self.store.requestFullAccessToReminders(completion: completion) }
                } else { self.store.requestAccess(to: kind == .calendar ? .event : .reminder, completion: completion) }
            }
        }
    }
    private func read<T: Sendable>(_ kind: IntegrationKind, _ body: @escaping @Sendable (EKEventStore) throws -> T) async throws -> T {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.access(kind) == .authorized else { continuation.resume(throwing: IntegrationError.unavailable); return }
                do { continuation.resume(returning: try body(self.store)) } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func lists(_ kind: IntegrationKind) async throws -> [IntegrationList] {
        try await read(kind) { store in
            store.calendars(for: kind == .calendar ? .event : .reminder)
                .map { IntegrationList(id: $0.calendarIdentifier, title: $0.title + " · " + $0.source.title) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
    func events(start: Date, end: Date, ids: Set<String>) async throws -> [AgendaEvent] {
        try await read(.calendar) { store in
            let calendars = store.calendars(for: .event).filter { ids.contains($0.calendarIdentifier) }
            guard !calendars.isEmpty else { return [] }
            return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars)).map {
                AgendaEvent(id: $0.calendarItemIdentifier + ":" + String($0.startDate.timeIntervalSince1970),
                            title: $0.title ?? "无标题事件", calendarTitle: $0.calendar.title,
                            start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay)
            }
        }
    }
    func reminders(ids: Set<String>) async throws -> [ReminderRecord] {
        try Task.checkCancellation()
        // EventKit's callback can arrive after cancellation. The service checks task cancellation and
        // selection revision before publishing, so an obsolete fetch can never import or update UI.
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.access(.reminders) == .authorized else { continuation.resume(throwing: IntegrationError.unavailable); return }
                let calendars = self.store.calendars(for: .reminder).filter { ids.contains($0.calendarIdentifier) }
                guard !calendars.isEmpty else { continuation.resume(returning: []); return }
                let predicate = self.store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars)
                self.store.fetchReminders(matching: predicate) { reminders in
                    self.queue.async {
                    guard self.access(.reminders) == .authorized else { continuation.resume(throwing: IntegrationError.unavailable); return }
                    guard let reminders else { continuation.resume(throwing: IntegrationError.fetchFailed); return }
                    continuation.resume(returning: reminders.filter { !$0.isCompleted }.map {
                        let components = $0.dueDateComponents
                        var calendar = components?.calendar ?? Calendar.current
                        if let zone = components?.timeZone { calendar.timeZone = zone }
                        return ReminderRecord(id: $0.calendarItemIdentifier, title: $0.title ?? "无标题提醒",
                                              notes: $0.notes ?? "", due: components.flatMap { calendar.date(from: $0) })
                    })
                    }
                }
            }
        }
    }
}
