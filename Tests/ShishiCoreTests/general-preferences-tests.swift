import XCTest
import ShishiCore
@testable import Shishi

final class GeneralPreferencesTests: XCTestCase {
    func testFailedArchiveKeepsMemoryAndUndo() async throws {
        try await MainActor.run {
            let name = "ShishiTests.archiveFailure.\(UUID())"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let preferences = GeneralPreferences(defaults: defaults)
            preferences.archiveTiming = .manually
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let folder = root.appendingPathComponent("library")
            let moved = root.appendingPathComponent("preserved")
            let store = TaskStore(fileURL: folder.appendingPathComponent("snapshot.json"), preferences: preferences)
            let task = Todo(title: "保留完成", schedule: .anytime)
            XCTAssertTrue(store.save(task))
            store.toggle(task.id)
            let previous = store.snapshot
            let canUndo = store.canUndo
            try FileManager.default.moveItem(at: folder, to: moved)
            try Data("blocked".utf8).write(to: folder)
            XCTAssertFalse(store.archiveCompletedItems())
            XCTAssertEqual(store.snapshot, previous)
            XCTAssertEqual(store.canUndo, canUndo)
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(try SnapshotFile(url: moved.appendingPathComponent("snapshot.json")).load(), previous)
        }
    }
    func testPreferencesAndArchiveTransactions() async throws {
        try await MainActor.run {
            let name = "ShishiTests.general.\(UUID())"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            let preferences = GeneralPreferences(defaults: defaults)
            XCTAssertEqual(preferences.appearance, 0)
            XCTAssertEqual(preferences.textSize, 14)
            XCTAssertTrue(preferences.groupToday)
            XCTAssertEqual(preferences.archiveTiming, .immediately)
            defaults.set(2, forKey: "appearance")
            XCTAssertEqual(preferences.appearance, 2)
            preferences.textSize = 100
            XCTAssertEqual(preferences.textSize, 20)
            preferences.textSize = 1
            XCTAssertEqual(preferences.textSize, 11)
            preferences.groupToday = false
            XCTAssertFalse(GeneralPreferences(defaults: defaults).groupToday)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("snapshot.json")
            let old = Todo(title: "旧历史", status: .completed, schedule: .anytime)
            try SnapshotFile(url: url).write(Snapshot(todos: [old]))
            preferences.archiveTiming = .manually
            let store = TaskStore(fileURL: url, preferences: preferences)
            XCTAssertEqual(store.items(for: .anytime).count, 0)
            let task = Todo(title: "新任务", schedule: .anytime, repeatRule: RepeatRule(unit: .day))
            XCTAssertTrue(store.save(task))
            store.toggle(task.id)
            XCTAssertNotNil(store.todo(task.id)?.pendingArchiveDate)
            XCTAssertTrue(store.items(for: .anytime).contains { $0.id == task.id })
            XCTAssertEqual(store.items(for: .logbook).map(\.id), [old.id])
            XCTAssertEqual(try SnapshotFile(url: url).load(), store.snapshot)
            XCTAssertTrue(store.archiveCompletedItems())
            XCTAssertNil(store.todo(task.id)?.pendingArchiveDate)
            store.undo()
            XCTAssertNotNil(store.todo(task.id)?.pendingArchiveDate)
            store.redo()
            XCTAssertNil(store.todo(task.id)?.pendingArchiveDate)
            store.undo()
            preferences.archiveTiming = .immediately
            XCTAssertNil(store.todo(task.id)?.pendingArchiveDate)
            store.undo()
            XCTAssertNotNil(store.todo(task.id)?.pendingArchiveDate)
            store.toggle(task.id)
            XCTAssertNil(store.todo(task.id)?.pendingArchiveDate)
            XCTAssertEqual(store.todos.count, 3, "重复后继仅创建一次")
            preferences.archiveTiming = .daily
            let daily = Todo(title: "当天完成", schedule: .anytime)
            XCTAssertTrue(store.save(daily))
            store.toggle(daily.id)
            XCTAssertNotNil(store.todo(daily.id)?.pendingArchiveDate)
            XCTAssertTrue(store.refreshArchiveTiming())
            XCTAssertNotNil(store.todo(daily.id)?.pendingArchiveDate)
            let p = Project(title: "项目")
            XCTAssertTrue(store.saveProject(p))
            XCTAssertTrue(store.setProjectCompleted(p.id, completed: true))
            XCTAssertNotNil(store.snapshot.projects.first { $0.id == p.id }?.pendingArchiveDate)
            XCTAssertTrue(store.refreshArchiveTiming(now: Calendar.current.date(byAdding: .day, value: 1, to: Date())!))
            XCTAssertNil(store.snapshot.projects.first { $0.id == p.id }?.pendingArchiveDate)
            XCTAssertNil(store.todo(daily.id)?.pendingArchiveDate)
        }
    }

    func testDailyBoundaryLegacyDecodeAndDockUnion() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var completed = Todo(title: "完成", status: .completed, schedule: .anytime)
        completed.pendingArchiveDate = now
        var snapshot = Snapshot(todos: [completed])
        CompletionArchive.apply(to: &snapshot, timing: .daily, now: now, calendar: calendar)
        XCTAssertNotNil(snapshot.todos[0].pendingArchiveDate)
        CompletionArchive.apply(to: &snapshot, timing: .daily, now: calendar.date(byAdding: .day, value: 1, to: now)!, calendar: calendar)
        XCTAssertNil(snapshot.todos[0].pendingArchiveDate)
        let data = try JSONEncoder().encode(snapshot)
        XCTAssertNil(try JSONDecoder().decode(Snapshot.self, from: data).todos[0].pendingArchiveDate)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var legacyTasks = try XCTUnwrap(legacy["todos"] as? [[String: Any]])
        legacyTasks[0].removeValue(forKey: "pendingArchiveDate")
        legacy["todos"] = legacyTasks
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        let oldSnapshot = try JSONDecoder().decode(Snapshot.self, from: oldData)
        XCTAssertEqual(Domain.items(in: oldSnapshot, for: .anytime).count, 0)
        XCTAssertEqual(Domain.items(in: oldSnapshot, for: .logbook).count, 1)
        let due = Todo(title: "到期且今天", schedule: .dated, startDate: now, deadline: now)
        let today = Todo(title: "今天", schedule: .dated, startDate: now)
        let inbox = Todo(title: "收件箱")
        var deleted = due; deleted.id = UUID(); deleted.deletedAt = now
        var closedProject = Project(title: "关闭项目", completed: true)
        closedProject.pendingArchiveDate = now
        let child = Todo(title: "关闭项目子项", deadline: now, projectID: closedProject.id)
        let project = Project(title: "到期项目", deadline: now)
        snapshot = Snapshot(todos: [due, today, inbox, completed, deleted, child], projects: [project, closedProject])
        XCTAssertEqual(DockCounts.count(in: snapshot, mode: .none, now: now, calendar: calendar), 0)
        XCTAssertEqual(DockCounts.count(in: snapshot, mode: .due, now: now, calendar: calendar), 2)
        XCTAssertEqual(DockCounts.count(in: snapshot, mode: .today, now: now, calendar: calendar), 3)
        XCTAssertEqual(DockCounts.count(in: snapshot, mode: .inbox, now: now, calendar: calendar), 4)
    }
}
