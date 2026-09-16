import XCTest
import ShishiCore
@testable import Shishi

final class QuickEntryTests: XCTestCase {
    func testTerminationProtectsHiddenDraftAndDefaultsToCancel() async {
        await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = makeStore(folder.appendingPathComponent("library.json"))
            let defaults = UserDefaults(suiteName: "ShishiQuickEntryTerminationTests." + UUID().uuidString)!
            let coordinator = QuickEntryCoordinator(store: store, currentRoute: { .inbox }, defaults: defaults)
            XCTAssertTrue(coordinator.prepareToTerminate()) // 不创建面板、不显示提示。
            let draft = QuickEntryDraft(destination: .today)
            XCTAssertTrue(draft.prepareToTerminate(store: store, route: .inbox))
            draft.title = "未提交"; draft.notes = "隐藏后也保留"
            draft.present(); draft.cancel()
            XCTAssertFalse(draft.prepareToTerminate(store: store, route: .inbox))
            XCTAssertEqual(draft.title, "未提交"); XCTAssertEqual(draft.notes, "隐藏后也保留")
            XCTAssertEqual(draft.destination, .today); XCTAssertFalse(draft.isPresented)
            XCTAssertTrue(store.todos.isEmpty)
            XCTAssertTrue(draft.prepareToTerminate(store: store, route: .inbox, choice: .save))
            XCTAssertTrue(draft.isEmpty); XCTAssertFalse(draft.isPresented)
            XCTAssertEqual(store.todos.last?.schedule, .dated)
            draft.title = "丢弃标题"; draft.notes = "丢弃备注"; draft.present(); draft.cancel()
            XCTAssertTrue(draft.prepareToTerminate(store: store, route: .inbox, choice: .discard))
            XCTAssertTrue(draft.isEmpty); XCTAssertFalse(draft.isPresented); XCTAssertTrue(draft.message.isEmpty)
            XCTAssertEqual(store.todos.count, 1)
        }
    }

    func testTerminationRefusesEmptyTitleAndDiskFailureWithoutLosingContent() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("library.json")
            let store = makeStore(url)
            let draft = QuickEntryDraft(destination: .currentList)
            draft.title = " \n"; draft.notes = "只有备注"; draft.cancel()
            XCTAssertFalse(draft.prepareToTerminate(store: store, route: .inbox, choice: .save))
            XCTAssertEqual(draft.title, " \n"); XCTAssertEqual(draft.notes, "只有备注")
            XCTAssertEqual(draft.message, "请输入任务标题。"); XCTAssertTrue(store.todos.isEmpty)
            draft.title = "保存失败"
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertFalse(draft.prepareToTerminate(store: store, route: .inbox, choice: .save))
            XCTAssertEqual(draft.title, "保存失败"); XCTAssertEqual(draft.notes, "只有备注")
            XCTAssertEqual(draft.destination, .currentList); XCTAssertFalse(draft.message.isEmpty)
            XCTAssertTrue(store.todos.isEmpty)
            XCTAssertTrue(draft.prepareToTerminate(store: store, route: .inbox, choice: .discard))
            XCTAssertTrue(draft.isEmpty)
        }
    }

    @MainActor private func makeStore(_ url: URL) -> TaskStore {
        let defaults = UserDefaults(suiteName: "ShishiQuickEntryStoreTests." + UUID().uuidString)!
        return TaskStore(fileURL: url, preferences: GeneralPreferences(defaults: defaults))
    }
    func testPreferencesValidationPersistenceAndNotification() async {
        let notified = expectation(description: "偏好通知")
        await MainActor.run {
            let suite = "ShishiQuickEntryTests." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set("invalid", forKey: "Shishi.quickEntry.shortcut")
            defaults.set("invalid", forKey: "Shishi.quickEntry.destination")
            let preferences = QuickEntryPreferences(defaults: defaults)
            XCTAssertTrue(preferences.enabled)
            XCTAssertEqual(preferences.shortcut, .controlOptionSpace)
            XCTAssertEqual(preferences.destination, .inbox)
            let observer = NotificationCenter.default.addObserver(forName: QuickEntryPreferences.changed, object: preferences, queue: nil) { _ in notified.fulfill() }
            preferences.enabled = false
            NotificationCenter.default.removeObserver(observer)
            preferences.shortcut = .controlOptionN; preferences.destination = .currentList
            let restored = QuickEntryPreferences(defaults: defaults)
            XCTAssertFalse(restored.enabled); XCTAssertEqual(restored.shortcut, .controlOptionN); XCTAssertEqual(restored.destination, .currentList)
            XCTAssertNil(QuickEntryShortcut(rawValue: "Command+Q"))
        }
        await fulfillment(of: [notified], timeout: 1)
    }

    func testDestinationsAndStaleRouteFallback() async {
        await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = makeStore(folder.appendingPathComponent("library.json"))
            let draft = QuickEntryDraft(destination: .inbox)
            draft.title = "收件"; XCTAssertTrue(draft.save(store: store, route: .today)); XCTAssertEqual(store.todos.last?.schedule, .inbox)
            draft.destination = .today; draft.title = "今天"
            let now = Date(timeIntervalSince1970: 1700000000)
            XCTAssertTrue(draft.save(store: store, route: .inbox, now: now)); XCTAssertEqual(store.todos.last?.startDate, Calendar.current.startOfDay(for: now))
            let area = Area(title: "区域"); XCTAssertTrue(store.saveArea(area))
            let project = Project(title: "项目", areaID: area.id); XCTAssertTrue(store.saveProject(project))
            draft.destination = .currentList; draft.title = "项目任务"
            XCTAssertTrue(draft.save(store: store, route: .project(project.id))); XCTAssertEqual(store.todos.last?.projectID, project.id)
            store.trashProject(project.id); draft.title = "回退"
            XCTAssertTrue(draft.save(store: store, route: .project(project.id))); XCTAssertEqual(store.todos.last?.schedule, .inbox); XCTAssertNil(store.todos.last?.projectID); XCTAssertTrue(draft.message.contains("收件箱"))
            for route: Route in [.search("关键词"), .trash, .logbook, .upcoming, .area(UUID())] {
                draft.title = "无效位置"; XCTAssertTrue(draft.save(store: store, route: route)); XCTAssertEqual(store.todos.last?.schedule, .inbox)
            }
            draft.title = "区域任务"; XCTAssertTrue(draft.save(store: store, route: .area(area.id))); XCTAssertEqual(store.todos.last?.areaID, area.id)
        }
    }

    func testValidationCancelFailureAndSuccessRetainDraftCorrectly() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("library.json")
            let store = makeStore(url)
            let draft = QuickEntryDraft(destination: .today)
            draft.present(); draft.title = " \n "; draft.notes = "保留备注"
            XCTAssertFalse(draft.save(store: store, route: .inbox)); XCTAssertTrue(draft.isPresented); XCTAssertTrue(store.todos.isEmpty)
            draft.title = "未提交"; draft.cancel(); XCTAssertFalse(draft.isPresented); XCTAssertEqual(draft.title, "未提交"); XCTAssertEqual(draft.notes, "保留备注")
            draft.present(); XCTAssertEqual(draft.destination, .today)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertFalse(draft.save(store: store, route: .inbox)); XCTAssertEqual(draft.title, "未提交"); XCTAssertEqual(draft.notes, "保留备注"); XCTAssertTrue(draft.isPresented); XCTAssertFalse(draft.message.isEmpty)
            try FileManager.default.removeItem(at: url)
            XCTAssertTrue(draft.save(store: store, route: .inbox)); XCTAssertTrue(draft.isEmpty); XCTAssertFalse(draft.isPresented); XCTAssertEqual(store.todos.count, 1)
        }
    }
}
