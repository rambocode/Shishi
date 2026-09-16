import AppKit
import XCTest
import ShishiCore
@testable import Shishi

private final class ProjectScrollCalendarProvider: SystemIntegrationProvider {
    func access(_ kind: IntegrationKind) -> IntegrationAccess { .denied }
    func request(_ kind: IntegrationKind) async throws { throw IntegrationError.unavailable }
    func lists(_ kind: IntegrationKind) async throws -> [IntegrationList] { [] }
    func events(start: Date, end: Date, ids: Set<String>) async throws -> [AgendaEvent] { [] }
    func reminders(ids: Set<String>) async throws -> [ReminderRecord] { [] }
}

final class ProjectScrollTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private func settle(_ view: NSView) {
        // TextKit测量依赖容器宽度，给原生约束和文字布局有限次收敛机会。
        for _ in 0..<6 { view.layoutSubtreeIfNeeded() }
    }
    @MainActor private func fixture(_ body: (TaskListController, TaskStore, Project, NSWindow) throws -> Void) throws {
        _ = NSApplication.shared
        let name = "Shishi.ProjectScrollTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: folder) }
        let preferences = GeneralPreferences(defaults: defaults)
        let store = TaskStore(fileURL: folder.appendingPathComponent("library.json"), preferences: preferences)
        let project = Project(title: "整页滚动项目", notes: (1...180).map { "第\($0)段：项目备注完整保留，滚动之后才到待办。" }.joined(separator: "\n"))
        XCTAssertTrue(store.saveProject(project))
        XCTAssertTrue(store.save(Todo(title: "备注后待办", schedule: .anytime, projectID: project.id,
                                      checklist: [ChecklistItem(title: "检查项内容")])) )
        let service = SystemIntegrations(defaults: defaults, provider: ProjectScrollCalendarProvider())
        let list = TaskListController(store: store, calendarService: service)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = list
        // 未显示的NSWindow接入控制器后需显式分配内容尺寸，否则clip可能仍为零高。
        window.setContentSize(NSSize(width: 900, height: 650))
        defer { window.contentViewController = nil; window.close() }
        list.route = .project(project.id); settle(list.view)
        try body(list, store, project, window)
    }

    func testLongProjectIsOneScrollDocumentAndWindowStaysFixed() async throws {
        try await MainActor.run {
            try fixture { list, _, project, window in
                let originalFrame = window.frame
                let table = try XCTUnwrap(descendants(list.view).compactMap { $0 as? NSTableView }.first)
                let scroll = try XCTUnwrap(table.enclosingScrollView)
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertGreaterThan(scroll.contentSize.height, 0)
                let notes = try XCTUnwrap(descendants(list.view).compactMap { $0 as? BoundedNotesView }.first)
                XCTAssertFalse(document === table)
                XCTAssertTrue(notes.isDescendant(of: document))
                XCTAssertEqual(notes.stringValue, project.notes)
                XCTAssertFalse(notes.hasVerticalScroller)
                XCTAssertGreaterThan(notes.intrinsicContentSize.height, 160)
                XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height * 2)
                let title = try XCTUnwrap(descendants(document).compactMap { $0 as? NSTextField }.first { $0.stringValue == project.title })
                XCTAssertGreaterThanOrEqual(title.convert(title.bounds, to: scroll.contentView).minY, 0)
                table.scrollRowToVisible(0); settle(list.view)
                XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
                let taskRect = table.convert(table.rect(ofRow: 0), to: document)
                XCTAssertTrue(scroll.documentVisibleRect.intersects(taskRect))
                XCTAssertEqual(window.frame, originalFrame)
                XCTAssertLessThan(title.convert(title.bounds, to: document).maxY, scroll.documentVisibleRect.minY)
                let footer = try XCTUnwrap(descendants(list.view).compactMap { $0 as? NSButton }.first { $0.toolTip == "新建待办" })
                XCTAssertFalse(footer.isDescendant(of: document))
            }
        }
    }

    func testReloadPreservesOffsetRouteChangeResetsAndEditingRemainsReachable() async throws {
        try await MainActor.run {
            try fixture { list, store, project, _ in
                let table = try XCTUnwrap(descendants(list.view).compactMap { $0 as? NSTableView }.first)
                let scroll = try XCTUnwrap(table.enclosingScrollView)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: 250)); scroll.reflectScrolledClipView(scroll.contentView)
                list.reload(); settle(list.view)
                XCTAssertEqual(scroll.contentView.bounds.minY, 250, accuracy: 2)
                let task = try XCTUnwrap(store.todos.first)
                list.beginEditing(task, isNew: false); settle(list.view)
                let editor = try XCTUnwrap(list.inlineEditor)
                let document = try XCTUnwrap(scroll.documentView)
                XCTAssertTrue(editor.isDescendant(of: document))
                XCTAssertTrue(scroll.documentVisibleRect.intersects(editor.convert(editor.bounds, to: document)))
                XCTAssertEqual(editor.collect().checklist.first?.title, "检查项内容")
                list.cancelInlineEditing(); list.route = .inbox; settle(list.view)
                XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 2)
                list.route = .project(project.id); settle(list.view)
                XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 2)
            }
        }
    }

    func testProjectNotesReflowAtNarrowWidthAndShrinkWithoutInnerScrollbar() async throws {
        try await MainActor.run {
            try fixture { list, store, project, window in
                let notes = try XCTUnwrap(descendants(list.view).compactMap { $0 as? BoundedNotesView }.first)
                let fullText = String(repeating: "项目长文本随宽度重排但不会丢失。", count: 80)
                var updated = project; updated.notes = fullText
                XCTAssertTrue(store.saveProject(updated)); settle(list.view)
                let wide = notes.intrinsicContentSize.height
                window.setContentSize(NSSize(width: 520, height: 560)); settle(list.view)
                XCTAssertGreaterThan(notes.intrinsicContentSize.height, wide)
                XCTAssertEqual(notes.stringValue, fullText); XCTAssertFalse(notes.hasVerticalScroller)
                updated.notes = "短备注"; XCTAssertTrue(store.saveProject(updated)); settle(list.view)
                XCTAssertLessThan(notes.intrinsicContentSize.height, 50)
                XCTAssertFalse(notes.hasVerticalScroller)
            }
        }
    }
}
