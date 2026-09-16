import XCTest
import Foundation
import CSQLite
@testable import ShishiCore
@testable import Shishi

private final class ThingsFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("thingsdatabase")
    var url: URL { folder.appendingPathComponent("main.sqlite") }
    private var database: OpaquePointer?
    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw DataError.invalid("无法创建合成测试库") }
        try execute("""
        CREATE TABLE TMArea(uuid TEXT PRIMARY KEY, title TEXT, "index" INTEGER);
        CREATE TABLE TMTask(uuid TEXT PRIMARY KEY, title TEXT, type INTEGER DEFAULT 0, status INTEGER DEFAULT 0,
          start INTEGER DEFAULT 1, startDate INTEGER, deadline INTEGER, startBucket INTEGER DEFAULT 0,
          notes TEXT, trashed INTEGER DEFAULT 0, area TEXT, project TEXT, heading TEXT, "index" INTEGER DEFAULT 0, todayIndex INTEGER, reminderTime INTEGER, deadlineSuppressionDate INTEGER,
          creationDate REAL DEFAULT 1725753600, stopDate REAL, rt1_recurrenceRule BLOB, rt1_repeatingTemplate TEXT,
          rt1_instanceCreationPaused INTEGER DEFAULT 0, rt1_nextInstanceStartDate INTEGER, repeater BLOB);
        CREATE TABLE TMTag(uuid TEXT PRIMARY KEY, title TEXT, parent TEXT, "index" INTEGER);
        CREATE TABLE TMTaskTag(tasks TEXT, tags TEXT);
        CREATE TABLE TMAreaTag(areas TEXT, tags TEXT);
        CREATE TABLE TMChecklistItem(uuid TEXT PRIMARY KEY, title TEXT, status INTEGER DEFAULT 0, task TEXT, "index" INTEGER DEFAULT 0);
        INSERT INTO TMArea VALUES('short-area','工作',0),('other-area','个人',1);
        INSERT INTO TMTask(uuid,title,type,area) VALUES('short-project','合成项目',1,'short-area');
        INSERT INTO TMTask(uuid,title,type,project) VALUES('short-heading','准备',2,'short-project');
        INSERT INTO TMTask(uuid,title,type,area,trashed) VALUES('trash-project','已删项目',1,'other-area',1);
        INSERT INTO TMTask(uuid,title,heading,notes,startDate,deadline,startBucket,"index")
          VALUES('short-todo','合成任务','short-heading','保留备注',132750976,132751104,1,2);
        INSERT INTO TMTask(uuid,title,start,"index") VALUES('inbox','收集',0,0);
        INSERT INTO TMTask(uuid,title,status,stopDate,project) VALUES('done','完成',3,1725754600,'short-project'),('canceled','取消',2,1725754601,'short-project');
        INSERT INTO TMTask(uuid,title,trashed) VALUES('own-trash','自身删除',1);
        INSERT INTO TMTask(uuid,title,project) VALUES('context-trash','父项目删除','trash-project');
        INSERT INTO TMTask(uuid,title,notes) VALUES('blank',NULL,'空标题仍有备注');
        INSERT INTO TMChecklistItem VALUES('check-a','第一项',3,'short-todo',0),('check-b','第二项',0,'short-todo',1),('check-empty','',0,'blank',0);
        INSERT INTO TMTag VALUES('short-tag','重点',NULL,0);
        INSERT INTO TMTag VALUES('unused-tag','未用',NULL,1),('area-tag','继承','short-tag',2);
        INSERT INTO TMTaskTag VALUES('short-todo','short-tag');
        INSERT INTO TMAreaTag VALUES('short-area','area-tag');
        """)
    }
    deinit { sqlite3_close(database); try? FileManager.default.removeItem(at: folder) }
    func execute(_ sql: String) throws {
        let code = sqlite3_exec(database, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw DataError.invalid("合成 SQL 失败：\(code)") }
    }
    func addRule(_ object: [String: Any], encoding: PropertyListSerialization.PropertyListFormat? = nil) throws {
        let data: Data
        if let encoding { data = try PropertyListSerialization.data(fromPropertyList: object, format: encoding, options: 0) }
        else { data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        try execute("INSERT INTO TMTask(uuid,title,rt1_recurrenceRule) VALUES('template','重复模板',X'\(hex)'); INSERT INTO TMTask(uuid,title,rt1_repeatingTemplate,startDate) VALUES('instance','当前实例','template',132750976);")
    }
}

final class ThingsImportTests: XCTestCase {
    private var simpleRule: [String: Any] { ["rrv": 4, "tp": 1, "fu": 16, "fa": 2, "of": [["dy": 0]], "rc": 0, "ts": 0, "ed": Int64(64_092_211_200), "ia": 1725753600, "sr": 1725753600] }

    func testRealSchemaShortIDsFieldsAndSourceUnchanged() throws {
        let fixture = try ThingsFixture()
        let before = try Data(contentsOf: fixture.url)
        let result = try ThingsImporter.read(from: fixture.folder)
        XCTAssertEqual(result.snapshot.todos.count, 7)
        XCTAssertEqual(result.snapshot.projects.count, 2)
        XCTAssertEqual(result.snapshot.areas.count, 2)
        let task = try XCTUnwrap(result.snapshot.todos.first { $0.source?.identifier == "short-todo" })
        XCTAssertEqual(task.projectID, ThingsID.make("short-project", kind: "task"))
        XCTAssertEqual(task.headingID, ThingsID.make("short-heading", kind: "task"))
        XCTAssertEqual(task.areaID, ThingsID.make("short-area", kind: "area"))
        XCTAssertEqual(task.notes, "保留备注")
        XCTAssertEqual(task.tags, ["重点"])
        XCTAssertEqual(task.checklist.map(\.completed), [true, false])
        XCTAssertTrue(task.evening)
        XCTAssertEqual(task.schedule, .dated)
        XCTAssertNotEqual(task.startDate, task.deadline)
        XCTAssertEqual(task.createdAt, Date(timeIntervalSince1970: 1725753600))
        XCTAssertEqual(result.snapshot.todos.first { $0.source?.identifier == "canceled" }?.status, .canceled)
        XCTAssertEqual(Domain.items(in: result.snapshot, for: .trash).count, 2)
        XCTAssertEqual(result.snapshot.projects.filter { $0.deletedAt != nil }.count, 1)
        XCTAssertTrue(result.warnings.contains { $0.contains("废纸篓项目") })
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertTrue(try ThingsImporter.read(from: fixture.url).snapshot == result.snapshot)
    }
    func testEmptyTitlesPreserveRecordsNotesChecklistAndNullMetadata() throws {
        let fixture = try ThingsFixture()
        let result = try ThingsImporter.read(from: fixture.url)
        let task = try XCTUnwrap(result.snapshot.todos.first { $0.source?.identifier == "blank" })
        XCTAssertEqual(task.notes, "空标题仍有备注")
        XCTAssertEqual(task.source?.metadata["originalTitle"], "")
        XCTAssertEqual(task.source?.metadata["originalTitleWasNull"], "true")
        XCTAssertEqual(task.checklist.count, 1)
        XCTAssertEqual(task.checklist[0].source?.metadata["originalTitle"], "")
        XCTAssertEqual(task.checklist[0].source?.metadata["originalTitleWasNull"], "false")
        XCTAssertTrue(result.warnings.contains { $0.contains("空标题任务") })
        XCTAssertTrue(result.warnings.contains { $0.contains("空标题清单项") })
        try Domain.validate(result.snapshot)
    }
    func testPackedDateLeapAndInvalidCalendarDate() throws {
        XCTAssertNotNil(try ThingsValues.date(Int64((2024 << 16) | (2 << 12) | (29 << 7))))
        XCTAssertThrowsError(try ThingsValues.date(Int64((2023 << 16) | (2 << 12) | (29 << 7))))
        XCTAssertThrowsError(try ThingsValues.date(-1))
        XCTAssertThrowsError(try ThingsValues.date(1_800_000_000))
        XCTAssertNil(try ThingsValues.date(0))
        for year in [2050, 2099, 9999] { XCTAssertNotNil(try ThingsValues.date(Int64((year << 16) | (12 << 12) | (31 << 7)))) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let date = try XCTUnwrap(ThingsValues.date(132464128))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day], from: date), DateComponents(year: 2021, month: 3, day: 28))
    }
    func testSchemaAliasAndStrictInvalidReferences() throws {
        let fixture = try ThingsFixture()
        try fixture.execute("ALTER TABLE TMTask RENAME COLUMN heading TO actionGroup;")
        let result = try ThingsImporter.read(from: fixture.url)
        XCTAssertNotNil(result.snapshot.todos.first { $0.source?.identifier == "short-todo" }?.headingID)
        try fixture.execute("UPDATE TMTask SET project='absent-project' WHERE uuid='short-heading';")
        XCTAssertThrowsError(try ThingsImporter.read(from: fixture.url))
    }
    func testUnknownStatusOrMissingRequiredSchemaRejectWholeImport() throws {
        let fixture = try ThingsFixture()
        try fixture.execute("UPDATE TMTask SET status=1 WHERE uuid='inbox';")
        XCTAssertThrowsError(try ThingsImporter.read(from: fixture.url))
        try fixture.execute("UPDATE TMTask SET status=0 WHERE uuid='inbox'; ALTER TABLE TMTask RENAME COLUMN start TO unsupportedStart;")
        XCTAssertThrowsError(try ThingsImporter.read(from: fixture.url))
    }
    func testJSONAndXMLPlistRepeatsLinkExistingInstancesWithoutCreatingNewOnes() throws {
        for format in [nil, PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let fixture = try ThingsFixture()
            try fixture.addRule(simpleRule, encoding: format)
            let result = try ThingsImporter.read(from: fixture.url)
            XCTAssertEqual(result.snapshot.todos.count, 9)
            let template = try XCTUnwrap(result.snapshot.todos.first { $0.source?.identifier == "template" })
            let instance = try XCTUnwrap(result.snapshot.todos.first { $0.source?.identifier == "instance" })
            XCTAssertEqual(template.source?.metadata["repeatTemplate"], "true")
            XCTAssertEqual(instance.repeatRule, RepeatRule(unit: .day, interval: 2))
            XCTAssertNotNil(instance.source?.metadata["raw:rt1_recurrenceRule"])
            XCTAssertNil(instance.source?.metadata["repeatTemplate"])
            XCTAssertFalse(Domain.items(in: result.snapshot, for: .anytime).contains { $0.id == template.id })
        }
    }
    func testComplexRepeatRetainsRawAndWarns() throws {
        let fixture = try ThingsFixture()
        var rule = simpleRule; rule["of"] = [["wd": 1], ["wd": 3]]; rule["fu"] = 256
        try fixture.addRule(rule)
        let result = try ThingsImporter.read(from: fixture.url)
        let template = try XCTUnwrap(result.snapshot.todos.first { $0.source?.identifier == "template" })
        XCTAssertNil(template.repeatRule)
        XCTAssertTrue(template.notes.contains("Things 原始重复规则"))
        XCTAssertNotNil(template.source?.metadata["raw:rt1_recurrenceRule"])
        XCTAssertTrue(result.warnings.contains { $0.contains("不支持") })
    }
    func testSHA256KnownVectorAndStableNamespacing() {
        let digest = ThingsID.sha256(Array("abc".utf8)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(ThingsID.make("short", kind: "task"), ThingsID.make("short", kind: "task"))
        XCTAssertNotEqual(ThingsID.make("short", kind: "task"), ThingsID.make("short", kind: "area"))
    }
    func testStableMergeBackupTrashPreservationAndValidationRollback() async throws {
        let fixture = try ThingsFixture()
        let imported = try ThingsImporter.read(from: fixture.url).snapshot
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("library.json")
            let store = TaskStore(fileURL: url)
            let local = Todo(title: "本地未导入内容")
            XCTAssertTrue(store.save(local))
            let originalBytes = try Data(contentsOf: url)
            let first = try store.mergeImported(imported)
            XCTAssertEqual(first.added, imported.todos.count + imported.projects.count + imported.areas.count)
            XCTAssertEqual(first.updated, 0)
            XCTAssertEqual(store.todo(local.id), local)
            let backups = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains("backup-") }
            XCTAssertEqual(backups.count, 1); XCTAssertEqual(try Data(contentsOf: backups[0]), originalBytes)
            let second = try store.mergeImported(imported)
            XCTAssertEqual(second.added, 0); XCTAssertEqual(second.updated, 0)
            let id = ThingsID.make("short-todo", kind: "task")
            store.trash(id)
            let deletedAt = store.todo(id)?.deletedAt
            _ = try store.mergeImported(imported)
            XCTAssertEqual(store.todo(id)?.deletedAt, deletedAt)
            let projectID = ThingsID.make("short-project", kind: "task")
            store.trashProject(projectID)
            _ = try store.mergeImported(imported)
            XCTAssertNotNil(store.projects.first { $0.id == projectID }?.deletedAt)
            let before = store.snapshot, bytes = try Data(contentsOf: url)
            let collision = Snapshot(areas: [Area(id: local.id, title: "跨类型冲突")])
            XCTAssertThrowsError(try store.mergeImported(collision))
            XCTAssertTrue(store.snapshot == before); XCTAssertEqual(try Data(contentsOf: url), bytes)
            XCTAssertThrowsError(try store.mergeImported(Snapshot(version: 999)))
            XCTAssertTrue(store.snapshot == before)
            store.restoreProject(projectID)
            XCTAssertNil(store.projects.first { $0.id == projectID }?.deletedAt)
            XCTAssertEqual(store.todo(id)?.deletedAt, deletedAt)
        }
    }
    func testProjectTrashRestoreAndOldJSONCompatibility() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("db.json")
            let old = Snapshot(projects: [Project(title: "旧项目", headings: [Heading(title: "旧分组")])])
            try SnapshotFile(url: url).write(old)
            let store = TaskStore(fileURL: url)
            XCTAssertNil(store.errorMessage)
            XCTAssertNil(store.projects[0].deletedAt); XCTAssertNil(store.projects[0].status)
            let child = Todo(title: "子任务", schedule: .anytime, projectID: store.projects[0].id)
            XCTAssertTrue(store.save(child))
            store.trashProject(store.projects[0].id)
            XCTAssertTrue(store.items(for: .anytime).isEmpty)
            XCTAssertEqual(store.items(for: .trash).map(\.id), [child.id])
            store.restoreProject(store.projects[0].id)
            XCTAssertEqual(store.items(for: .anytime).map(\.id), [child.id])
            XCTAssertTrue(store.items(for: .trash).isEmpty)
        }
    }
    func testAuthorizedCopyCountsDatesAndSourceHash() throws {
        guard let path = ProcessInfo.processInfo.environment["SHISHI_THINGS_TEST_SOURCE"] else { throw XCTSkip("真实副本验证需显式设置 SHISHI_THINGS_TEST_SOURCE") }
        let url = URL(fileURLWithPath: path)
        let before = ThingsID.sha256(Array(try Data(contentsOf: url)))
        let result = try ThingsImporter.read(from: url)
        XCTAssertEqual(result.snapshot.todos.count, 920)
        XCTAssertEqual(result.snapshot.projects.count, 70)
        XCTAssertEqual(result.snapshot.projects.filter { $0.deletedAt != nil }.count, 17)
        XCTAssertEqual(result.snapshot.projects.flatMap(\.headings).count, 98)
        XCTAssertEqual(result.snapshot.areas.count, 3)
        XCTAssertEqual(result.snapshot.todos.flatMap(\.checklist).count, 532)
        XCTAssertEqual(result.snapshot.tags?.count, 7)
        XCTAssertEqual(result.sourceCounts["TMTag"], 7)
        XCTAssertEqual(Domain.items(in: result.snapshot, for: .today).count, 3)
        XCTAssertEqual(Domain.projects(in: result.snapshot, for: .today).count, 2)
        XCTAssertEqual(Domain.items(in: result.snapshot, for: .upcoming).count, 2)
        XCTAssertEqual(Domain.items(in: result.snapshot, for: .today).count + Domain.projects(in: result.snapshot, for: .today).count, 5)
        XCTAssertEqual(result.snapshot.todos.filter { $0.source?.metadata["repeatTemplate"] == "true" }.count, 3)
        XCTAssertEqual(result.snapshot.todos.filter { $0.repeatRule != nil && $0.source?.metadata["repeatTemplate"] != "true" }.count, 1)
        try Domain.validate(result.snapshot)
        XCTAssertTrue(ThingsID.sha256(Array(try Data(contentsOf: url))) == before, "源数据库哈希必须保持不变")
    }
}
