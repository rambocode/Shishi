import XCTest
import ShishiCore
@testable import Shishi

final class StoreTests: XCTestCase {
    func testTransactionsUndoRepeatAndTrash() async {
        await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("db.json")
            let store = TaskStore(fileURL: url)
            XCTAssertTrue(store.todos.isEmpty)
            let task = Todo(title: " 测试 ", repeatRule: RepeatRule(unit: .day, afterCompletion: true))
            XCTAssertTrue(store.save(task))
            XCTAssertEqual(store.todo(task.id)?.title, "测试")
            XCTAssertFalse(store.save(Todo(title: "坏引用", projectID: UUID())))
            XCTAssertEqual(store.todos.count, 1)
            store.toggle(task.id)
            XCTAssertEqual(store.todos.count, 2)
            store.toggle(task.id); store.toggle(task.id)
            XCTAssertEqual(store.todos.count, 2)
            store.undo()
            XCTAssertEqual(store.todo(task.id)?.status, .open)
            store.redo()
            XCTAssertEqual(store.todo(task.id)?.status, .completed)
            store.trash(task.id)
            XCTAssertEqual(store.items(for: .trash).count, 1)
            store.restore(task.id)
            XCTAssertEqual(store.items(for: .logbook).count, 1)
            store.permanentlyDelete(task.id)
            XCTAssertNotNil(store.todo(task.id))
            store.trash(task.id); store.permanentlyDelete(task.id)
            XCTAssertNil(store.todo(task.id))
            store.undo()
            XCTAssertNotNil(store.todo(task.id)?.deletedAt)
            XCTAssertEqual(TaskStore(fileURL: url).snapshot, store.snapshot)
        }
    }
    func testCorruptProtectionImportBackupAndExport() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("db.json")
            let broken = Data("broken".utf8)
            try broken.write(to: url)
            let store = TaskStore(fileURL: url, demo: true)
            XCTAssertNotNil(store.errorMessage)
            XCTAssertFalse(store.save(Todo(title: "不能覆盖")))
            XCTAssertEqual(try Data(contentsOf: url), broken)
            XCTAssertThrowsError(try store.exportData(to: folder.appendingPathComponent("export.json")))
            let source = folder.appendingPathComponent("source.json")
            try SnapshotFile(url: source).write(Snapshot(todos: [Todo(title: "有效")]))
            try store.importData(from: source)
            XCTAssertEqual(store.todos.count, 1)
            XCTAssertFalse(store.canUndo)
            let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("backup-") }
            XCTAssertEqual(backups.count, 1)
            XCTAssertEqual(try Data(contentsOf: backups[0]), broken)
            let exported = folder.appendingPathComponent("export.json")
            try store.exportData(to: exported)
            XCTAssertEqual(try SnapshotFile(url: exported).load(), store.snapshot)
            let previous = store.snapshot
            try Data("{\"version\":99,\"todos\":[],\"projects\":[],\"areas\":[]}".utf8).write(to: source)
            XCTAssertThrowsError(try store.importData(from: source))
            XCTAssertEqual(store.snapshot, previous)
            XCTAssertEqual(try SnapshotFile(url: url).load(), previous)
        }
    }
    func testDeleteRelationshipsAndFailedDiskWrite() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("db.json")
            let store = TaskStore(fileURL: url)
            let area = Area(title: "区域")
            let heading = Heading(title: "分组")
            let project = Project(title: "项目", areaID: area.id, headings: [heading])
            XCTAssertTrue(store.saveArea(area)); XCTAssertTrue(store.saveProject(project))
            let task = Todo(title: "任务", projectID: project.id, headingID: heading.id)
            XCTAssertTrue(store.save(task))
            store.deleteProject(project.id)
            XCTAssertNil(store.todo(task.id)?.projectID)
            XCTAssertNil(store.todo(task.id)?.headingID)
            XCTAssertEqual(store.todo(task.id)?.areaID, area.id)
            store.deleteArea(area.id)
            XCTAssertNil(store.todo(task.id)?.areaID)
            let previous = store.snapshot
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertFalse(store.save(Todo(title: "写入失败")))
            XCTAssertEqual(store.snapshot, previous)
        }
    }
}
