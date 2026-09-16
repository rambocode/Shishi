import XCTest
import ShishiCore
@testable import Shishi

final class ArchiveBoundaryTests: XCTestCase {
    func testBackupRestoreAppliesPolicyBeforePublishingAndSurvivesRestart() async throws {
        try await MainActor.run {
            let now = Date()
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
            var old = Todo(title: "昨天完成", status: .completed, schedule: .anytime, completedAt: yesterday)
            old.pendingArchiveDate = yesterday
            var recent = Todo(title: "今天取消", status: .canceled, schedule: .anytime, completedAt: now)
            recent.pendingArchiveDate = now
            var project = Project(title: "昨天完成项目", completed: true)
            project.pendingArchiveDate = yesterday
            var child = Todo(title: "父项目待归档时刚完成", status: .completed, schedule: .anytime,
                             projectID: project.id, completedAt: now)
            child.pendingArchiveDate = now
            let backup = Snapshot(todos: [old, recent, child], projects: [project])
            for timing in ArchiveTiming.allCases {
                let name = "ShishiTests.restore.\(UUID())"
                let defaults = UserDefaults(suiteName: name)!
                defer { defaults.removePersistentDomain(forName: name) }
                let preferences = GeneralPreferences(defaults: defaults)
                preferences.archiveTiming = timing
                let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: root) }
                let url = root.appendingPathComponent("library.json")
                let source = root.appendingPathComponent("backup.json")
                try SnapshotFile(url: source).write(backup)
                let store = TaskStore(fileURL: url, preferences: preferences)
                XCTAssertTrue(store.save(Todo(title: "恢复前")))
                let before = store.snapshot
                try store.importData(from: source)
                let restored = store.snapshot
                XCTAssertEqual(store.todo(old.id)?.pendingArchiveDate, timing == .manually ? yesterday : nil)
                XCTAssertEqual(store.todo(recent.id)?.pendingArchiveDate, timing == .immediately ? nil : now)
                XCTAssertEqual(restored.projects[0].pendingArchiveDate, timing == .manually ? yesterday : nil)
                XCTAssertEqual(store.todo(child.id)?.pendingArchiveDate, timing == .manually ? now : nil)
                XCTAssertEqual(try SnapshotFile(url: url).load(), restored)
                XCTAssertEqual(try SnapshotFile(url: source).load(), backup, "源备份不被改写")
                XCTAssertEqual(TaskStore(fileURL: url, preferences: preferences).snapshot, restored)
                store.undo()
                XCTAssertEqual(store.snapshot, before, "恢复及归档只有一个撤销事务")
                store.redo()
                XCTAssertEqual(store.snapshot, restored)
                XCTAssertEqual(try SnapshotFile(url: url).load(), restored)
            }
        }
    }

    func testSameSourceClosedMergePreservesPendingAndUpdatesImportedFields() throws {
        let now = Date()
        let next = now.addingTimeInterval(60)
        let area = Area(title: "原区域")
        let target = Area(title: "新区域")
        let heading = Heading(title: "本地分组")
        var project = Project(title: "本地项目", areaID: area.id, completed: true, headings: [heading],
                              source: SourceInfo(provider: "Things", identifier: "project"))
        project.pendingArchiveDate = now
        var task = Todo(title: "本地任务", status: .completed, schedule: .anytime,
                        projectID: project.id, areaID: area.id, completedAt: now,
                        deletedAt: now, source: SourceInfo(provider: "Things", identifier: "task"))
        task.pendingArchiveDate = now
        let current = Snapshot(todos: [task], projects: [project], areas: [area, target])
        var importedProject = project
        importedProject.title = "导入更新项目"; importedProject.areaID = target.id
        importedProject.headings = []; importedProject.pendingArchiveDate = nil
        importedProject.source?.metadata["updated"] = "true"
        var importedTask = task
        importedTask.title = "导入更新任务"; importedTask.notes = "更新备注"
        importedTask.status = .canceled; importedTask.completedAt = next
        importedTask.areaID = target.id; importedTask.pendingArchiveDate = nil; importedTask.deletedAt = nil
        importedTask.source?.metadata["updated"] = "true"
        var incoming = Snapshot(todos: [importedTask], projects: [importedProject], areas: [target])
        let result = try ImportedMerge.merge(incoming, into: current)
        XCTAssertEqual(result.added, 0); XCTAssertEqual(result.updated, 2)
        XCTAssertEqual(result.snapshot.todos[0].pendingArchiveDate, now)
        XCTAssertEqual(result.snapshot.projects[0].pendingArchiveDate, now)
        XCTAssertEqual(result.snapshot.todos[0].title, importedTask.title)
        XCTAssertEqual(result.snapshot.todos[0].notes, importedTask.notes)
        XCTAssertEqual(result.snapshot.todos[0].status, .canceled)
        XCTAssertEqual(result.snapshot.todos[0].completedAt, next)
        XCTAssertEqual(result.snapshot.todos[0].areaID, target.id)
        XCTAssertEqual(result.snapshot.todos[0].deletedAt, now)
        XCTAssertEqual(result.snapshot.projects[0].headings, [heading])
        XCTAssertEqual(result.snapshot.projects[0].source, importedProject.source)
        XCTAssertEqual(try ImportedMerge.merge(incoming, into: result.snapshot).updated, 0)

        incoming.todos[0].status = .open; incoming.todos[0].completedAt = nil
        incoming.todos[0].pendingArchiveDate = next
        incoming.projects[0].completed = false; incoming.projects[0].status = .open
        incoming.projects[0].pendingArchiveDate = next
        let reopened = try ImportedMerge.merge(incoming, into: result.snapshot).snapshot
        XCTAssertNil(reopened.todos[0].pendingArchiveDate)
        XCTAssertNil(reopened.projects[0].pendingArchiveDate)
        XCTAssertEqual(reopened.todos[0].status, .open)
        XCTAssertFalse(reopened.projects[0].completed)
        XCTAssertEqual(reopened.todos[0].deletedAt, now)

        incoming.todos[0] = importedTask; incoming.projects[0] = importedProject
        incoming.todos[0].pendingArchiveDate = next; incoming.projects[0].pendingArchiveDate = next
        let explicit = try ImportedMerge.merge(incoming, into: current).snapshot
        XCTAssertEqual(explicit.todos[0].pendingArchiveDate, next)
        XCTAssertEqual(explicit.projects[0].pendingArchiveDate, next)
        incoming.todos[0].pendingArchiveDate = nil; incoming.projects[0].pendingArchiveDate = nil
        incoming.todos[0].source?.identifier = "another-task"
        incoming.projects[0].source?.provider = "another-provider"
        let unrelated = try ImportedMerge.merge(incoming, into: current).snapshot
        XCTAssertNil(unrelated.todos[0].pendingArchiveDate)
        XCTAssertNil(unrelated.projects[0].pendingArchiveDate)
    }

    func testDailyParentArchiveMakesFreshClosedChildrenVisibleInHistory() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let midnight = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let beforeMidnight = midnight.addingTimeInterval(-1)
        let now = midnight.addingTimeInterval(1)
        var project = Project(title: "昨日完成项目", completed: true)
        project.pendingArchiveDate = beforeMidnight
        var closed = Todo(title: "午夜刚完成子项", status: .completed, schedule: .anytime,
                          projectID: project.id, completedAt: now)
        closed.pendingArchiveDate = now
        var canceled = Todo(title: "午夜刚取消子项", status: .canceled, schedule: .anytime,
                            projectID: project.id, completedAt: now)
        canceled.pendingArchiveDate = now
        let open = Todo(title: "开放子项", schedule: .anytime, projectID: project.id)
        var independent = Todo(title: "独立当天完成", status: .completed, schedule: .anytime, completedAt: now)
        independent.pendingArchiveDate = now
        let original = Snapshot(todos: [closed, canceled, open, independent], projects: [project])
        var value = original
        CompletionArchive.apply(to: &value, timing: .daily, now: now, calendar: calendar)
        XCTAssertNil(value.projects[0].pendingArchiveDate)
        XCTAssertNil(value.todos[0].pendingArchiveDate)
        XCTAssertNil(value.todos[1].pendingArchiveDate)
        XCTAssertEqual(value.todos[2], open)
        XCTAssertEqual(value.todos[3], independent)
        XCTAssertEqual(Set(Domain.items(in: value, for: .logbook, now: now, calendar: calendar).map(\.id)), Set([closed.id, canceled.id]))
        XCTAssertEqual(Set(ProjectSummary(project: value.projects[0], tasks: value.todos).recordedItems.filter { $0.pendingArchiveDate == nil }.map(\.id)), Set([closed.id, canceled.id]))
        try Domain.validate(value)
        var manual = original
        CompletionArchive.apply(to: &manual, timing: .manually, now: now, calendar: calendar)
        XCTAssertEqual(manual, original, "仍未归档的父项目不提前归档子项")
        manual.projects[0].pendingArchiveDate = nil
        CompletionArchive.apply(to: &manual, timing: .manually, now: now, calendar: calendar)
        XCTAssertNil(manual.todos[0].pendingArchiveDate, "修复备份/合并已有的已归档父项目")
        XCTAssertEqual(manual.todos[3], independent)
    }
}
