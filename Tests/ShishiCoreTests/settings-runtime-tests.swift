import AppKit
import XCTest
import ShishiCore
@testable import Shishi

private final class SettingsRuntimeCalendarProvider: SystemIntegrationProvider {
    func access(_ kind: IntegrationKind) -> IntegrationAccess { .denied }
    func request(_ kind: IntegrationKind) async throws { throw IntegrationError.unavailable }
    func lists(_ kind: IntegrationKind) async throws -> [IntegrationList] { [] }
    func events(start: Date, end: Date, ids: Set<String>) async throws -> [AgendaEvent] { [] }
    func reminders(ids: Set<String>) async throws -> [ReminderRecord] { [] }
}

final class SettingsRuntimeTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    @MainActor private func fixture(_ body: (TaskStore, GeneralPreferences, SystemIntegrations) throws -> Void) throws {
        _ = NSApplication.shared
        let suite = "Shishi.SettingsRuntimeTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let preferences = GeneralPreferences(defaults: defaults)
        let store = TaskStore(fileURL: directory.appendingPathComponent("library.json"), preferences: preferences)
        let calendar = SystemIntegrations(defaults: defaults, provider: SettingsRuntimeCalendarProvider())
        try body(store, preferences, calendar)
    }

    @MainActor private func table(in view: NSView) throws -> NSTableView {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSTableView }.first)
    }

    @MainActor private func rowViews(_ list: TaskListController, _ table: NSTableView) throws -> [NSView] {
        try (0..<list.numberOfRows(in: table)).map {
            try XCTUnwrap(list.tableView(table, viewFor: table.tableColumns.first, row: $0))
        }
    }

    @MainActor private func labels(in view: NSView) -> [NSTextField] {
        descendants(view).compactMap { $0 as? NSTextField }
    }

    func testTodayGroupingChangesRealRowsAndDisplayOrderWithoutReorderingStore() async throws {
        try await MainActor.run {
            try fixture { store, preferences, calendar in
                let a = Project(title: "分组甲", schedule: .anytime)
                let b = Project(title: "分组乙", schedule: .anytime)
                XCTAssertTrue(store.saveProject(a)); XCTAssertTrue(store.saveProject(b))
                let today = Calendar.current.startOfDay(for: Date())
                let tasks = [
                    Todo(title: "甲一", schedule: .dated, startDate: today, projectID: a.id, order: 0),
                    Todo(title: "乙一", schedule: .dated, startDate: today, projectID: b.id, order: 1),
                    Todo(title: "甲二", schedule: .dated, startDate: today, projectID: a.id, order: 2)
                ]
                for task in tasks { XCTAssertTrue(store.save(task)) }
                let before = store.snapshot
                let list = TaskListController(store: store, calendarService: calendar)
                let table = try table(in: list.view)
                @MainActor func displayed() throws -> [String] {
                    try rowViews(list, table).flatMap { labels(in: $0).map(\.stringValue) }
                        .filter { tasks.map(\.title).contains($0) }
                }
                preferences.groupToday = false
                XCTAssertEqual(try displayed(), ["甲一", "乙一", "甲二"])
                XCTAssertEqual(list.numberOfRows(in: table), 4, "一个今天标题及三个任务")
                preferences.groupToday = true
                XCTAssertEqual(try displayed(), ["甲一", "甲二", "乙一"])
                XCTAssertEqual(list.numberOfRows(in: table), 5, "两个项目分组标题及三个任务")
                let headings = try rowViews(list, table).flatMap { labels(in: $0).map(\.stringValue) }
                XCTAssertTrue(headings.contains("今天 · 分组甲"))
                XCTAssertTrue(headings.contains("今天 · 分组乙"))
                preferences.groupToday = false
                XCTAssertEqual(try displayed(), ["甲一", "乙一", "甲二"])
                XCTAssertEqual(store.snapshot, before, "显示分组不得改 order、todayIndex 或其他持久化字段")
            }
        }
    }

    func testMaximumAndDefaultTextSizeUpdateActualListAndSidebarControls() async throws {
        try await MainActor.run {
            try fixture { store, preferences, calendar in
                let task = Todo(title: "字号任务", schedule: .anytime)
                XCTAssertTrue(store.save(task))
                let before = store.snapshot
                let list = TaskListController(store: store, calendarService: calendar)
                _ = list.view; list.route = .anytime
                let sidebar = SidebarController(store: store)
                let listTable = try table(in: list.view)
                let sidebarTable = try table(in: sidebar.view)
                for size in [20, 14] {
                    preferences.textSize = size
                    let visibleRows = try rowViews(list, listTable)
                    let taskIndex = try XCTUnwrap(visibleRows.firstIndex {
                        labels(in: $0).contains { $0.stringValue == task.title }
                    })
                    let row = visibleRows[taskIndex]
                    let title = try XCTUnwrap(labels(in: row).first { $0.stringValue == task.title })
                    XCTAssertEqual(title.font?.pointSize, CGFloat(size))
                    XCTAssertEqual(list.tableView(listTable, heightOfRow: taskIndex), CGFloat(size + 14))
                    let inbox = try XCTUnwrap(sidebar.tableView(sidebarTable, viewFor: sidebarTable.tableColumns.first, row: 0))
                    let inboxTitle = try XCTUnwrap(labels(in: inbox).first { $0.stringValue == "收件箱" })
                    XCTAssertEqual(inboxTitle.font?.pointSize, CGFloat(size))
                    XCTAssertEqual(sidebar.tableView(sidebarTable, heightOfRow: 0), CGFloat(size + 15))
                }
                XCTAssertEqual(store.snapshot, before)
            }
        }
    }

    func testTextSizeChangesPreserveActiveInlineInputAndFirstResponder() async throws {
        try await MainActor.run {
            try fixture { store, preferences, calendar in
                let task = Todo(title: "原始标题", notes: "原始备注", schedule: .anytime)
                XCTAssertTrue(store.save(task))
                let before = store.snapshot
                let list = TaskListController(store: store, calendarService: calendar)
                _ = list.view; list.route = .anytime
                // 只使用未显示的窗口建立 responder 链；不激活应用、不发送键鼠事件。
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = list.view
                defer { window.contentView = nil }
                list.beginEditing(task, isNew: false)
                let editor = try XCTUnwrap(list.inlineEditor)
                let notes = try XCTUnwrap(descendants(editor).compactMap { $0 as? NSTextView }.first {
                    $0.string == task.notes
                })
                notes.string = "尚未保存的备注与输入"
                notes.setSelectedRange(NSRange(location: 3, length: 2))
                XCTAssertTrue(window.makeFirstResponder(notes))
                XCTAssertTrue(window.firstResponder === notes)
                let selection = notes.selectedRange()
                let draft = editor.collect()
                for size in [20, 14] {
                    preferences.textSize = size
                    XCTAssertTrue(list.inlineEditor === editor, "偏好通知不得替换活动编辑卡片")
                    XCTAssertTrue(window.firstResponder === notes)
                    XCTAssertEqual(notes.selectedRange(), selection)
                    XCTAssertEqual(editor.collect(), draft)
                    XCTAssertEqual(store.snapshot, before, "改字号不能提交未保存输入")
                }
                list.cancelInlineEditing()
                let table = try table(in: list.view)
                let row = try XCTUnwrap(try rowViews(list, table).first {
                    labels(in: $0).contains { $0.stringValue == task.title }
                })
                XCTAssertEqual(labels(in: row).first { $0.stringValue == task.title }?.font?.pointSize, 14)
                XCTAssertFalse(window.isVisible)
            }
        }
    }
}
