import XCTest
import ShishiCore
@testable import Shishi

private final class FakeIntegrations: SystemIntegrationProvider {
    var status: IntegrationAccess = .notDetermined
    var requests = 0
    var reads = 0
    var range: (Date, Date)?
    var eventValues: [AgendaEvent] = []
    var reminderValues: [ReminderRecord] = []
    var pending: CheckedContinuation<[ReminderRecord], Error>?
    var delay = false
    var fails = false
    func access(_ kind: IntegrationKind) -> IntegrationAccess { status }
    func request(_ kind: IntegrationKind) async throws { requests += 1; status = .authorized }
    func lists(_ kind: IntegrationKind) async throws -> [IntegrationList] { reads += 1; return [IntegrationList(id: "a", title: "Fake")] }
    func events(start: Date, end: Date, ids: Set<String>) async throws -> [AgendaEvent] { reads += 1; range = (start, end); return eventValues }
    func reminders(ids: Set<String>) async throws -> [ReminderRecord] {
        reads += 1
        if fails { throw IntegrationError.fetchFailed }
        if delay { return try await withCheckedThrowingContinuation { pending = $0 } }
        return reminderValues
    }
}

final class SystemIntegrationsTests: XCTestCase {
    @MainActor private func fixture() -> (SystemIntegrations, FakeIntegrations, UserDefaults) {
        let defaults = UserDefaults(suiteName: "ShishiIntegrationsTests.\(UUID())")!
        let fake = FakeIntegrations()
        return (SystemIntegrations(defaults: defaults, provider: fake), fake, defaults)
    }
    @MainActor func testUnauthorizedAndDisabledNeverReadOrRequest() async throws {
        let (service, fake, _) = fixture()
        XCTAssertFalse(service.calendarEnabled)
        service.calendarIDs = ["a"]; service.reminderIDs = ["a"]
        for status in [IntegrationAccess.notDetermined, .denied, .restricted, .writeOnly] {
            fake.status = status; service.calendarEnabled = true
            XCTAssertFalse(service.calendarEnabled)
            let lists = try await service.lists(.calendar)
            let events = try await service.events(for: .today)
            let reminders = try await service.previewReminders()
            XCTAssertTrue(lists.isEmpty); XCTAssertTrue(events.isEmpty); XCTAssertTrue(reminders.isEmpty)
        }
        fake.status = .authorized
        _ = try await service.events(for: .today)
        XCTAssertEqual(fake.reads, 0); XCTAssertEqual(fake.requests, 0)
        try await service.requestAccess(.calendar)
        XCTAssertEqual(fake.requests, 1)
    }
    @MainActor func testPersistenceAndLocalDayRangesAcrossDST() async throws {
        let (service, fake, defaults) = fixture(); fake.status = .authorized
        service.calendarIDs = ["a"]; service.reminderIDs = ["a"]; service.calendarEnabled = true
        let restored = SystemIntegrations(defaults: defaults, provider: fake)
        XCTAssertTrue(restored.calendarEnabled); XCTAssertEqual(restored.calendarIDs, ["a"])
        XCTAssertEqual(restored.reminderIDs, ["a"])
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12))!
        let start = calendar.startOfDay(for: now), end = calendar.date(byAdding: .day, value: 1, to: start)!
        fake.eventValues = [AgendaEvent(id: "overlap", title: "跨日", calendarTitle: "Fake", start: start.addingTimeInterval(-3600), end: start.addingTimeInterval(3600), allDay: false),
                            AgendaEvent(id: "end", title: "边界", calendarTitle: "Fake", start: end, end: end.addingTimeInterval(3600), allDay: false)]
        let events = try await service.events(for: .today, now: now, calendar: calendar)
        XCTAssertEqual(events.map(\.id), ["overlap"])
        XCTAssertEqual(fake.range?.1.timeIntervalSince(start), 23 * 3600)
        _ = try await service.events(for: .upcoming, now: now, calendar: calendar)
        XCTAssertEqual(fake.range?.1, calendar.date(byAdding: .day, value: 7, to: start))
        fake.status = .denied
        let revoked = try await service.events(for: .today)
        XCTAssertTrue(revoked.isEmpty)
    }
    @MainActor func testImportIsAtomicIdempotentAndKeepsLocalEdits() throws {
        let (service, fake, _) = fixture(); fake.status = .authorized
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TaskStore(fileURL: directory.appendingPathComponent("tasks.json"))
        let record = ReminderRecord(id: "stable", title: "提醒", notes: "原文", due: nil)
        XCTAssertEqual(try service.importReminders([record, record], into: store), 1)
        var local = store.todos[0]; local.title = "本地修改"; XCTAssertTrue(store.save(local))
        XCTAssertEqual(try service.importReminders([record], into: store), 0)
        XCTAssertEqual(store.todos[0].title, "本地修改")
        XCTAssertEqual(fake.reads, 0); XCTAssertEqual(fake.requests, 0)
        // A protected malformed library must remain unchanged, and retry into a valid library works.
        let invalid = directory.appendingPathComponent("bad.json")
        try Data("invalid".utf8).write(to: invalid)
        let protected = TaskStore(fileURL: invalid)
        XCTAssertThrowsError(try service.importReminders([record], into: protected))
        XCTAssertTrue(protected.todos.isEmpty)
        XCTAssertEqual(try Data(contentsOf: invalid), Data("invalid".utf8))
    }
    @MainActor func testObsoleteAndCancelledPreviewNeverPublishes() async throws {
        let (service, fake, _) = fixture(); fake.status = .authorized; fake.delay = true; service.reminderIDs = ["a"]
        let task = Task { try await service.previewReminders() }
        while fake.pending == nil { await Task.yield() }
        service.reminderIDs = ["b"]
        fake.pending?.resume(returning: [ReminderRecord(id: "old", title: "旧请求", notes: "", due: nil)]); fake.pending = nil
        do { _ = try await task.value; XCTFail("Expected obsolete request rejection") } catch {}
        let cancelled = Task { try await service.previewReminders() }
        while fake.pending == nil { await Task.yield() }
        cancelled.cancel(); fake.pending?.resume(returning: []); fake.pending = nil
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    @MainActor func testPreviewFailureRetryAndRevocation() async throws {
        let (service, fake, _) = fixture(); fake.status = .authorized; service.reminderIDs = ["a"]
        fake.fails = true
        do { _ = try await service.previewReminders(); XCTFail("Expected failure") } catch {}
        fake.fails = false; fake.reminderValues = [ReminderRecord(id: "retry", title: "重试", notes: "", due: nil)]
        let retried = try await service.previewReminders()
        XCTAssertEqual(retried.map(\.id), ["retry"])
        fake.delay = true
        let revoked = Task { try await service.previewReminders() }
        while fake.pending == nil { await Task.yield() }
        fake.status = .denied; fake.pending?.resume(returning: fake.reminderValues); fake.pending = nil
        do { _ = try await revoked.value; XCTFail("Expected permission rejection") } catch {}
        XCTAssertEqual(fake.requests, 0)
    }
    @MainActor func testChangedNotificationAndNoAutomaticReminderRead() async throws {
        let (service, fake, _) = fixture(); fake.status = .authorized
        let changed = expectation(description: "Public integration change")
        let observer = NotificationCenter.default.addObserver(forName: SystemIntegrations.changed, object: service, queue: .main) { _ in changed.fulfill() }
        service.reminderIDs = ["a"]
        await fulfillment(of: [changed], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
        XCTAssertEqual(fake.reads, 0)
        _ = try await service.lists(.reminders)
        XCTAssertEqual(fake.reads, 1); XCTAssertEqual(fake.requests, 0)
    }
}
