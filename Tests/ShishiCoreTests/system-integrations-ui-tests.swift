import AppKit
import XCTest
import ShishiCore
@testable import Shishi

private final class UIIntegrationProvider: SystemIntegrationProvider {
    var status: IntegrationAccess = .notDetermined
    var requests = 0
    var listReads = 0
    var eventReads = 0
    var reminderReads = 0
    var failEvents = false
    var eventValues: [AgendaEvent] = []
    var requestContinuation: CheckedContinuation<Void, Error>?
    var reminderContinuation: CheckedContinuation<[ReminderRecord], Error>?
    var reminderWasCancelled = false
    func access(_ kind: IntegrationKind) -> IntegrationAccess { status }
    func request(_ kind: IntegrationKind) async throws {
        requests += 1
        try await withCheckedThrowingContinuation { requestContinuation = $0 }
        status = .authorized
    }
    func lists(_ kind: IntegrationKind) async throws -> [IntegrationList] {
        listReads += 1; return [IntegrationList(id: "fake-list", title: "测试列表")]
    }
    func events(start: Date, end: Date, ids: Set<String>) async throws -> [AgendaEvent] {
        eventReads += 1
        if failEvents { throw IntegrationError.fetchFailed }
        return eventValues
    }
    func reminders(ids: Set<String>) async throws -> [ReminderRecord] {
        reminderReads += 1
        let value: [ReminderRecord] = try await withCheckedThrowingContinuation { reminderContinuation = $0 }
        reminderWasCancelled = Task.isCancelled
        return value
    }
}

final class SystemIntegrationsUITests: XCTestCase {
    @MainActor private func fixture() -> (SystemIntegrations, UIIntegrationProvider) {
        let provider = UIIntegrationProvider()
        return (SystemIntegrations(defaults: UserDefaults(suiteName: "ShishiIntegrationUI.\(UUID())")!, provider: provider), provider)
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private func button(_ title: String, in view: NSView) -> NSButton? {
        descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title }
    }
    @MainActor private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("UI did not reach expected state")
    }
    @MainActor func testUnauthorizedPanesAndAgendaNeverReadOrRequest() async throws {
        let (service, provider) = fixture()
        let store = TaskStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("tasks.json"))
        for status in [IntegrationAccess.notDetermined, .denied, .restricted, .writeOnly] {
            provider.status = status
            let calendar = CalendarSettingsPane(service: service)
            let reminders = RemindersSettingsPane(service: service, store: store)
            calendar.loadView(); reminders.loadView()
            XCTAssertNotNil(button("授权读取日历", in: calendar.view))
            XCTAssertNotNil(button("授权读取提醒事项", in: reminders.view))
            XCTAssertNil(button("预览所选列表的未完成提醒", in: reminders.view))
            let agenda = CalendarAgendaView(service: service); agenda.frame.size.width = 560
            agenda.update(route: .today)
            try await Task.sleep(nanoseconds: 10_000_000)
            XCTAssertTrue(agenda.isHidden)
            XCTAssertEqual(agenda.constraints.first { $0.firstAttribute == .height }?.constant, 0)
            calendar.viewWillDisappear(); reminders.viewWillDisappear()
        }
        XCTAssertEqual(provider.requests, 0); XCTAssertEqual(provider.listReads, 0)
        XCTAssertEqual(provider.eventReads, 0); XCTAssertEqual(provider.reminderReads, 0)
    }
    @MainActor func testAgendaErrorIsVisibleAndRetryOnlyReads() async throws {
        let (service, provider) = fixture(); provider.status = .authorized
        service.calendarIDs = ["fake-list"]; service.calendarEnabled = true; provider.failEvents = true
        let agenda = CalendarAgendaView(service: service); agenda.frame = NSRect(x: 0, y: 0, width: 560, height: 120)
        agenda.update(route: .today)
        try await settle { agenda.errorMessage != nil }
        XCTAssertFalse(agenda.isHidden)
        let retry = try XCTUnwrap(button("重试", in: agenda))
        XCTAssertFalse(retry.isHidden)
        XCTAssertTrue(descendants(agenda).compactMap { $0 as? NSTextField }.contains { $0.stringValue == agenda.errorMessage })
        let start = Calendar.current.startOfDay(for: Date())
        provider.failEvents = false
        provider.eventValues = [AgendaEvent(id: "event", title: "恢复的事件", calendarTitle: "测试", start: start, end: start.addingTimeInterval(3600), allDay: false)]
        retry.performClick(nil)
        try await settle { descendants(agenda).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("恢复的事件") } }
        XCTAssertNil(agenda.errorMessage); XCTAssertTrue(retry.isHidden)
        XCTAssertEqual(provider.eventReads, 2); XCTAssertEqual(provider.requests, 0)
    }
    @MainActor func testAgendaDocumentFitsWrappedEventsAndScrollsBeyondViewport() async throws {
        let (service, provider) = fixture(); provider.status = .authorized
        service.calendarIDs = ["fake-list"]; service.calendarEnabled = true
        let start = Calendar.current.startOfDay(for: Date())
        provider.eventValues = (0..<12).map { index in
            AgendaEvent(id: String(index), title: "事件\(index) " + String(repeating: "较长的测试标题", count: 10), calendarTitle: "测试日历",
                        start: start.addingTimeInterval(Double(index) * 60), end: start.addingTimeInterval(Double(index) * 60 + 3600), allDay: false)
        }
        let agenda = CalendarAgendaView(service: service); agenda.frame = NSRect(x: 0, y: 0, width: 560, height: 120)
        agenda.update(route: .today)
        try await settle { !agenda.isHidden }
        agenda.layoutSubtreeIfNeeded()
        let scroll = try XCTUnwrap(agenda.subviews.first as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        let label = try XCTUnwrap(document.subviews.first as? NSTextField)
        XCTAssertTrue(scroll.hasVerticalScroller)
        XCTAssertEqual(agenda.constraints.first { $0.firstAttribute == .height }?.constant, 120)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height)
        XCTAssertGreaterThanOrEqual(document.frame.height, label.frame.maxY)
        XCTAssertLessThanOrEqual(label.frame.maxX, document.frame.width)
        XCTAssertTrue(label.stringValue.contains("事件11"))
        let wideHeight = document.frame.height
        agenda.frame.size.width = 320; agenda.needsLayout = true; agenda.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(document.frame.height, wideHeight)
        scroll.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - scroll.contentView.bounds.height)); scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
        XCTAssertEqual(provider.requests, 0)
    }
    @MainActor func testAuthorizationButtonsDisableWhilePendingAndReenableAfterRejection() async throws {
        for kind in [IntegrationKind.calendar, .reminders] {
            let (service, provider) = fixture()
            let store = TaskStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("tasks.json"))
            let pane: NSViewController = kind == .calendar ? CalendarSettingsPane(service: service) : RemindersSettingsPane(service: service, store: store)
            pane.loadView()
            let title = kind == .calendar ? "授权读取日历" : "授权读取提醒事项"
            let authorize = try XCTUnwrap(button(title, in: pane.view))
            authorize.performClick(nil); XCTAssertFalse(authorize.isEnabled)
            try await settle { provider.requestContinuation != nil }
            try await settle { descendants(pane.view).compactMap { $0 as? NSButton }.contains { $0.title.contains("正在请求") && !$0.isEnabled } }
            authorize.performClick(nil)
            try await service.requestAccess(kind)
            XCTAssertEqual(provider.requests, 1)
            provider.requestContinuation?.resume(throwing: IntegrationError.fetchFailed); provider.requestContinuation = nil
            try await settle { button(title, in: pane.view)?.isEnabled == true }
            XCTAssertFalse(service.isRequestingAccess(kind))
            pane.viewWillDisappear()
        }
    }
    @MainActor func testReminderPreviewCancelsOnExitAndReopenRefreshesWithoutImport() async throws {
        let (service, provider) = fixture(); provider.status = .authorized; service.reminderIDs = ["fake-list"]
        let store = TaskStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("tasks.json"))
        let pane = RemindersSettingsPane(service: service, store: store); pane.loadView()
        try await settle { button("预览所选列表的未完成提醒", in: pane.view) != nil }
        button("预览所选列表的未完成提醒", in: pane.view)?.performClick(nil)
        try await settle { provider.reminderContinuation != nil }
        pane.viewWillDisappear()
        provider.reminderContinuation?.resume(returning: [ReminderRecord(id: "obsolete", title: "不应显示的结果", notes: "", due: nil)])
        provider.reminderContinuation = nil
        try await settle { provider.reminderWasCancelled }
        XCTAssertNil(button("不应显示的结果", in: pane.view)); XCTAssertTrue(store.todos.isEmpty)
        let reads = provider.listReads
        pane.viewWillAppear()
        try await settle { provider.listReads > reads && button("预览所选列表的未完成提醒", in: pane.view) != nil }
        XCTAssertEqual(provider.reminderReads, 1)
        provider.status = .denied; pane.viewWillDisappear(); pane.viewWillAppear()
        XCTAssertNotNil(button("授权读取提醒事项", in: pane.view))
        XCTAssertNil(button("预览所选列表的未完成提醒", in: pane.view))
        XCTAssertEqual(provider.requests, 0); XCTAssertTrue(store.todos.isEmpty)
        pane.viewWillDisappear()
    }
}
