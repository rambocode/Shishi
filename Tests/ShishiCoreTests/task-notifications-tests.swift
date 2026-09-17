import XCTest
import UserNotifications
import ShishiCore
@testable import Shishi

@MainActor private final class FakeTaskNotificationProvider: TaskNotificationProvider {
    var status: UNAuthorizationStatus = .authorized
    var requests: [String: TaskNotificationRequest] = [:]
    var authorizationRequests = 0
    var additions = 0
    var delegateInstalls = 0
    var failAdd = false
    var failAuthorization = false
    var grantAuthorization = true
    var pauseNextAdd = false
    var paused: CheckedContinuation<Void, Never>?
    func installDelegate() { delegateInstalls += 1 }
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        if failAuthorization { throw NSError(domain: "fake", code: 1) }
        status = grantAuthorization ? .authorized : .denied
        return grantAuthorization
    }
    func pendingRequests() async -> [TaskNotificationRequest] { Array(requests.values) }
    func removeRequests(_ identifiers: [String]) { for id in identifiers { requests.removeValue(forKey: id) } }
    func addRequest(_ request: TaskNotificationRequest) async throws {
        additions += 1
        if pauseNextAdd {
            pauseNextAdd = false
            await withCheckedContinuation { paused = $0 }
        }
        if failAdd { throw NSError(domain: "fake", code: 2) }
        requests[request.identifier] = request
    }
    func resume() { let continuation = paused; paused = nil; continuation?.resume() }
}

final class TaskNotificationsTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: 1_900_000_000)
    @MainActor private func makeStore() -> (TaskStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shishi-notification-test-" + UUID().uuidString)
        return (TaskStore(fileURL: folder.appendingPathComponent("db.json")), folder)
    }

    @MainActor func testUnbundledStartupKeepsReminderWithoutUsingSystemNotificationCenter() async throws {
        // XCTest 与 swift run 都不在 .app 包内；默认 provider 必须安全降级，不能触发 ObjC 异常。
        XCTAssertNotEqual(Bundle.main.bundleURL.pathExtension, "app")
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let saved = Todo(title: "命令行开发提醒", reminderDate: time.addingTimeInterval(100))
        XCTAssertTrue(store.save(saved))
        let service = TaskNotifications(store: store, now: { self.time })
        service.start()
        await service.waitForRefresh()
        XCTAssertTrue(service.scheduledIdentifiers.isEmpty)
        XCTAssertTrue(try XCTUnwrap(service.lastError).contains(".app"))
        let message = await service.authorizeAndRefresh()
        XCTAssertTrue(try XCTUnwrap(message).contains(".app"))
        XCTAssertEqual(store.todo(saved.id)?.reminderDate, saved.reminderDate)
    }

    func testLegacyCodableAndInvalidReminder() throws {
        let legacy = Todo(title: "旧 Things", source: SourceInfo(provider: "Things", identifier: "old", metadata: ["reminder": "true"]))
        let data = try JSONEncoder().encode(legacy)
        XCTAssertNil(try JSONDecoder().decode(Todo.self, from: data).reminderDate)
        var task = legacy; task.reminderDate = time
        XCTAssertEqual(try JSONDecoder().decode(Todo.self, from: JSONEncoder().encode(task)).reminderDate, time)
        task.reminderDate = Date(timeIntervalSinceReferenceDate: .infinity)
        XCTAssertThrowsError(try Domain.validate(Snapshot(todos: [task])))
    }

    @MainActor func testUnauthorizedStartDoesNotRequestOrScheduleAndLegacyMetadataIsIgnored() async {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertTrue(store.save(Todo(title: "已有显式提醒", reminderDate: time.addingTimeInterval(100))))
        for i in 0..<32 {
            XCTAssertTrue(store.save(Todo(title: "导入\(i)", source: SourceInfo(provider: "Things", identifier: "\(i)", metadata: ["reminder": "true"])) ))
        }
        let fake = FakeTaskNotificationProvider(); fake.status = .notDetermined
        let service = TaskNotifications(store: store, provider: fake, now: { self.time })
        service.start(); service.start()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(fake.delegateInstalls, 1); XCTAssertEqual(fake.authorizationRequests, 0); XCTAssertEqual(fake.additions, 0)
        let result = await service.authorizeAndRefresh()
        XCTAssertNil(result); XCTAssertEqual(fake.authorizationRequests, 1); XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(service.authorizationStatus, .authorized)
    }

    @MainActor func testRestartRepairsSavedReminderAndRemovesStaleQueue() async {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let saved = Todo(title: "重启恢复", reminderDate: time.addingTimeInterval(200))
        let closed = Todo(title: "已完成", status: .completed, reminderDate: time.addingTimeInterval(100))
        XCTAssertTrue(store.save(saved)); XCTAssertTrue(store.save(closed))
        let fake = FakeTaskNotificationProvider()
        let closedID = TaskNotifications.identifier(for: closed.id)
        let absentID = TaskNotifications.identifier(for: UUID())
        fake.requests[closedID] = TaskNotificationRequest(identifier: closedID, title: closed.title, date: closed.reminderDate!)
        fake.requests[absentID] = TaskNotificationRequest(identifier: absentID, title: "旧备份中已不存在", date: time.addingTimeInterval(100))
        let reopened = TaskStore(fileURL: folder.appendingPathComponent("db.json"))
        let service = TaskNotifications(store: reopened, provider: fake, now: { self.time })
        service.start(); await service.waitForRefresh()
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(fake.requests[TaskNotifications.identifier(for: saved.id)]?.date, saved.reminderDate)
        XCTAssertNil(fake.requests[closedID]); XCTAssertNil(fake.requests[absentID])
        XCTAssertEqual(fake.authorizationRequests, 0)
        // 拒绝权限的重启同样清理遗留队列，但保留本地数据且不弹权限。
        fake.status = .denied
        let deniedService = TaskNotifications(store: reopened, provider: fake, now: { self.time })
        deniedService.start(); await deniedService.waitForRefresh()
        XCTAssertTrue(fake.requests.isEmpty); XCTAssertNotNil(deniedService.lastError)
        XCTAssertEqual(reopened.todo(saved.id)?.reminderDate, saved.reminderDate)
        XCTAssertEqual(fake.authorizationRequests, 0)
    }

    @MainActor func testStoreChangesCancelUpdateUndoAndRestoreStableIdentifier() async {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let fake = FakeTaskNotificationProvider()
        let service = TaskNotifications(store: store, provider: fake, now: { self.time }); service.start()
        var task = Todo(title: "提醒", reminderDate: time.addingTimeInterval(100))
        let id = TaskNotifications.identifier(for: task.id)
        XCTAssertTrue(store.save(task)); await service.waitForRefresh()
        XCTAssertEqual(fake.requests[id]?.title, "提醒")
        task.title = "更新"; task.reminderDate = time.addingTimeInterval(200)
        XCTAssertTrue(store.save(task)); await service.waitForRefresh()
        XCTAssertEqual(fake.requests[id]?.date, task.reminderDate)
        task.reminderDate = nil; XCTAssertTrue(store.save(task)); await service.waitForRefresh()
        XCTAssertNil(fake.requests[id])
        store.undo(); await service.waitForRefresh(); XCTAssertEqual(fake.requests[id]?.title, "更新")
        store.cancel(task.id); await service.waitForRefresh(); XCTAssertNil(fake.requests[id])
        store.undo(); await service.waitForRefresh(); XCTAssertNotNil(fake.requests[id])
        store.trash(task.id); await service.waitForRefresh(); XCTAssertNil(fake.requests[id])
        store.restore(task.id); await service.waitForRefresh(); XCTAssertNotNil(fake.requests[id])
        store.toggle(task.id); await service.waitForRefresh(); XCTAssertNil(fake.requests[id])
        XCTAssertEqual(fake.authorizationRequests, 0)
    }

    @MainActor func testDeniedAndProviderFailuresPreserveLocalData() async {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let task = Todo(title: "本地提醒", reminderDate: time.addingTimeInterval(100)); XCTAssertTrue(store.save(task))
        let fake = FakeTaskNotificationProvider(); fake.status = .notDetermined; fake.grantAuthorization = false
        let service = TaskNotifications(store: store, provider: fake, now: { self.time })
        let denied = await service.authorizeAndRefresh(); XCTAssertNotNil(denied)
        XCTAssertEqual(service.authorizationStatus, .denied); XCTAssertEqual(store.todo(task.id)?.reminderDate, task.reminderDate)
        XCTAssertTrue(fake.requests.isEmpty)
        let deniedAgain = await service.authorizeAndRefresh(); XCTAssertNotNil(deniedAgain); XCTAssertEqual(fake.authorizationRequests, 1)
        fake.status = .authorized; fake.failAdd = true
        let failed = await service.authorizeAndRefresh(); XCTAssertNotNil(failed); XCTAssertTrue(service.scheduledIdentifiers.isEmpty)
        fake.failAdd = false
        let success = await service.authorizeAndRefresh(); XCTAssertNil(success); XCTAssertEqual(fake.requests.count, 1)
        fake.status = .denied; service.refresh(); await service.waitForRefresh(); XCTAssertTrue(fake.requests.isEmpty)
        fake.status = .notDetermined; fake.failAuthorization = true
        let requestFailure = await service.authorizeAndRefresh(); XCTAssertNotNil(requestFailure)
        XCTAssertEqual(store.todo(task.id)?.reminderDate, task.reminderDate)
    }

    @MainActor func testNearest64AndContainerDeletionAndTemplates() async {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let fake = FakeTaskNotificationProvider()
        let foreign = TaskNotificationRequest(identifier: "another.feature", title: "保留", date: time.addingTimeInterval(10))
        fake.requests[foreign.identifier] = foreign
        let service = TaskNotifications(store: store, provider: fake, now: { self.time }); service.start()
        for i in (1...70).reversed() { XCTAssertTrue(store.save(Todo(title: "\(i)", reminderDate: time.addingTimeInterval(Double(i * 10))))) }
        XCTAssertTrue(store.save(Todo(title: "过期", reminderDate: time)))
        XCTAssertTrue(store.save(Todo(title: "内部模板", source: SourceInfo(provider: "Things", identifier: "template", metadata: ["repeatTemplate": "true"]), reminderDate: time.addingTimeInterval(1))))
        await service.waitForRefresh()
        XCTAssertEqual(fake.requests.count, 64); XCTAssertEqual(service.scheduledIdentifiers.count, 63)
        XCTAssertNotNil(service.lastError)
        XCTAssertTrue(service.lastError?.contains("7 个任务") == true)
        XCTAssertTrue(service.lastError?.contains("64") == true)
        let capacityResult = await service.authorizeAndRefresh()
        XCTAssertNotNil(capacityResult); XCTAssertEqual(fake.authorizationRequests, 0)
        XCTAssertTrue(fake.requests.values.contains { $0.title == "1" }); XCTAssertFalse(fake.requests.values.contains { $0.title == "64" })
        XCTAssertEqual(fake.requests[foreign.identifier], foreign)
        let project = Project(title: "项目"); XCTAssertTrue(store.saveProject(project))
        let child = Todo(title: "子任务", projectID: project.id, reminderDate: time.addingTimeInterval(1)); XCTAssertTrue(store.save(child))
        await service.waitForRefresh(); XCTAssertNotNil(fake.requests[TaskNotifications.identifier(for: child.id)])
        store.trashProject(project.id); await service.waitForRefresh(); XCTAssertNil(fake.requests[TaskNotifications.identifier(for: child.id)])
        store.restoreProject(project.id); await service.waitForRefresh(); XCTAssertNotNil(fake.requests[TaskNotifications.identifier(for: child.id)])
        XCTAssertTrue(store.setProjectCompleted(project.id, completed: true)); await service.waitForRefresh()
        XCTAssertNil(fake.requests[TaskNotifications.identifier(for: child.id)])
    }

    @MainActor func testStaleAddRemovedAndSameIdentifierRepaired() async {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let fake = FakeTaskNotificationProvider(); fake.pauseNextAdd = true
        let service = TaskNotifications(store: store, provider: fake, now: { self.time }); service.start()
        var task = Todo(title: "旧", reminderDate: time.addingTimeInterval(100)); XCTAssertTrue(store.save(task))
        for _ in 0..<1000 { if fake.paused != nil { break }; await Task.yield() }
        XCTAssertNotNil(fake.paused)
        task.title = "新"; task.reminderDate = time.addingTimeInterval(200); XCTAssertTrue(store.save(task))
        fake.resume(); await service.waitForRefresh()
        let id = TaskNotifications.identifier(for: task.id)
        XCTAssertEqual(fake.requests[id]?.title, "新"); XCTAssertEqual(fake.requests[id]?.date, task.reminderDate)
        XCTAssertEqual(fake.requests.count, 1); XCTAssertEqual(fake.additions, 2)
        fake.pauseNextAdd = true; task.title = "将取消"; XCTAssertTrue(store.save(task))
        for _ in 0..<1000 { if fake.paused != nil { break }; await Task.yield() }
        XCTAssertNotNil(fake.paused)
        task.reminderDate = nil; XCTAssertTrue(store.save(task)); fake.resume(); await service.waitForRefresh()
        XCTAssertTrue(fake.requests.isEmpty); XCTAssertTrue(service.scheduledIdentifiers.isEmpty)
    }

    func testRepeatingTaskAndProjectShiftReminderAndDuplicateClearsIt() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let reminder = time.addingTimeInterval(3600)
        let task = Todo(title: "周期任务", schedule: .dated, startDate: time, repeatRule: RepeatRule(unit: .day), reminderDate: reminder)
        var snapshot = Snapshot(todos: [task])
        XCTAssertTrue(Domain.complete(task.id, in: &snapshot, now: time, calendar: calendar))
        XCTAssertEqual(snapshot.todos[1].reminderDate, calendar.date(byAdding: .day, value: 1, to: reminder))
        XCTAssertEqual(snapshot.todos[0].reminderDate, reminder)
        let project = Project(title: "周期项目", startDate: time, schedule: .dated, repeatRule: RepeatRule(unit: .week))
        let child = Todo(title: "子项", projectID: project.id, reminderDate: reminder)
        snapshot = Snapshot(todos: [child], projects: [project])
        let copied = try XCTUnwrap(ProjectOperations.duplicate(project.id, in: &snapshot))
        XCTAssertNil(snapshot.todos.first { $0.projectID == copied }?.reminderDate)
        var completed = project; completed.completed = true
        try ProjectOperations.save(completed, in: &snapshot, now: time, calendar: calendar)
        XCTAssertEqual(snapshot.todos.last?.reminderDate, calendar.date(byAdding: .day, value: 7, to: reminder))
        try Domain.validate(snapshot)
    }
}
