import AppKit
import XCTest
import ShishiCore
@testable import Shishi

/// 标题「…」菜单：存档、移动、转换为项目、删除。
final class HeadingActionsTests: XCTestCase {
    /// 项目 A 含两个标题；第一个标题下有一条开放、一条已完成待办；另有空的项目 B。
    @MainActor private func fixture(_ body: (TaskStore, TaskListController, Project, Project, [Todo]) throws -> Void) throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = TaskStore(fileURL: folder.appendingPathComponent("db.json"))
        let area = Area(title: "工作")
        XCTAssertTrue(store.saveArea(area))
        let first = Heading(title: "第一阶段", order: 0), second = Heading(title: "第二阶段", order: 1)
        let source = Project(title: "项目A", areaID: area.id, headings: [first, second], order: 0)
        let target = Project(title: "项目B", headings: [Heading(title: "已有", order: 3)], order: 1)
        XCTAssertTrue(store.saveProject(source)); XCTAssertTrue(store.saveProject(target))
        let open = Todo(title: "开放", schedule: .anytime, projectID: source.id, areaID: area.id, headingID: first.id)
        var done = Todo(title: "已完成", schedule: .anytime, projectID: source.id, areaID: area.id, headingID: first.id)
        done.status = .completed; done.completedAt = Date()
        let other = Todo(title: "其他标题", schedule: .anytime, projectID: source.id, areaID: area.id, headingID: second.id)
        for todo in [open, done, other] { XCTAssertTrue(store.save(todo)) }
        let list = TaskListController(store: store)
        _ = list.view
        list.route = .project(source.id)
        try body(store, list, source, target, [open, done, other])
    }

    func testMenuMatchesDesign() async throws {
        try await MainActor.run {
            try fixture { _, list, source, _, _ in
                let menu = list.headingMenu(source.headings[0].id, anchor: list.view)
                XCTAssertEqual(menu.titles, ["存档", "移动…", "转换为项目…", "删除"])
                guard case .separator = menu.entries[1] else { return XCTFail("存档后应有分隔线") }
                for case .item(let title, let icon, _, _) in menu.entries {
                    XCTAssertNotNil(icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }, title)
                }
                XCTAssertEqual(list.headingMoveMenu(source.headings[0].id).titles, ["项目B"], "移动目标不含当前项目")
            }
        }
    }

    func testArchiveCompletesOpenTasksAndHidesHeading() async throws {
        try await MainActor.run {
            try fixture { store, list, source, _, todos in
                let heading = source.headings[0].id
                list.headingMenu(heading, anchor: list.view).perform(title: "存档")
                XCTAssertEqual(store.todo(todos[0].id)?.status, .completed)
                XCTAssertEqual(store.todo(todos[2].id)?.status, .open, "其他标题不受影响")
                let saved = try XCTUnwrap(store.projects.first { $0.id == source.id }?.headings.first { $0.id == heading })
                XCTAssertEqual(saved.status, .completed)
                XCTAssertFalse(HeadingOperations.isVisible(saved))
                store.undo()
                XCTAssertEqual(store.todo(todos[0].id)?.status, .open, "一次撤销恢复整组")
            }
        }
    }

    func testMoveCarriesHeadingAndTasksToTargetProject() async throws {
        try await MainActor.run {
            try fixture { store, list, source, target, todos in
                var navigated: Route?
                list.onNavigate = { navigated = $0 }
                let heading = source.headings[0].id
                list.headingMoveMenu(heading).perform(title: "项目B")
                let moved = try XCTUnwrap(store.projects.first { $0.id == target.id })
                XCTAssertEqual(moved.headings.last?.id, heading)
                XCTAssertEqual(moved.headings.last?.order, 4, "追加到目标项目末尾")
                XCTAssertFalse(store.projects.first { $0.id == source.id }!.headings.contains { $0.id == heading })
                for id in [todos[0].id, todos[1].id] {
                    XCTAssertEqual(store.todo(id)?.projectID, target.id)
                    XCTAssertEqual(store.todo(id)?.headingID, heading)
                    XCTAssertNil(store.todo(id)?.areaID)
                }
                XCTAssertEqual(store.todo(todos[2].id)?.projectID, source.id)
                XCTAssertEqual(navigated, .project(target.id))
            }
        }
    }

    func testConvertCreatesProjectInSameAreaWithTasks() async throws {
        try await MainActor.run {
            try fixture { store, list, source, _, todos in
                var navigated: Route?
                list.onNavigate = { navigated = $0 }
                let heading = source.headings[0].id
                let id = try XCTUnwrap(list.convertHeadingToProject(heading))
                let project = try XCTUnwrap(store.projects.first { $0.id == id })
                XCTAssertEqual(project.title, "第一阶段")
                XCTAssertEqual(project.areaID, source.areaID)
                XCTAssertTrue(project.headings.isEmpty)
                XCTAssertEqual(store.projects.first { $0.id == source.id }?.headings.map(\.title), ["第二阶段"])
                for todo in todos.prefix(2) {
                    XCTAssertEqual(store.todo(todo.id)?.projectID, id)
                    XCTAssertNil(store.todo(todo.id)?.headingID)
                }
                XCTAssertEqual(navigated, .project(id))
            }
        }
    }

    func testDeleteMovesHeadingTasksToTrash() async throws {
        try await MainActor.run {
            try fixture { store, list, source, _, todos in
                let heading = source.headings[0].id
                list.headingMenu(heading, anchor: list.view).perform(title: "删除")
                XCTAssertNotNil(store.projects.first { $0.id == source.id }?.headings.first { $0.id == heading }?.deletedAt)
                let trash = Set(store.items(for: .trash).map(\.id))
                XCTAssertTrue(trash.contains(todos[0].id) && trash.contains(todos[1].id))
                XCTAssertFalse(trash.contains(todos[2].id))
                XCTAssertFalse(store.items(for: .project(source.id)).contains { $0.id == todos[0].id })
            }
        }
    }

    /// 存档后重新打开的待办仍指向已隐藏的标题，列表要把它放进无标题区而不是让它消失。
    func testTaskUnderArchivedHeadingStaysVisible() async throws {
        try await MainActor.run {
            try fixture { store, list, source, _, todos in
                list.archiveHeading(source.headings[0].id)
                store.reopenMany([todos[0].id])
                let table = try XCTUnwrap(allViews(list.view).compactMap { $0 as? NSTableView }.first)
                let ids = (0..<list.numberOfRows(in: table)).compactMap { list.task(at: $0)?.id }
                XCTAssertEqual(ids.first, todos[0].id)
            }
        }
    }

    /// 菜单优先显示在锚点下方右对齐；靠近窗口右下角时翻到上方，且不越出窗口内容区。
    func testMenuFrameStaysInsideWindow() async {
        await MainActor.run {
            let container = NSRect(x: 100, y: 100, width: 800, height: 600)
            let size = NSSize(width: 160, height: 130)
            let normal = InAppMenu.frame(size: size, anchor: NSRect(x: 400, y: 500, width: 24, height: 26), container: container)
            XCTAssertEqual(normal.maxX, 424); XCTAssertEqual(normal.maxY, 496)
            let corner = InAppMenu.frame(size: size, anchor: NSRect(x: 880, y: 120, width: 24, height: 26), container: container)
            XCTAssertTrue(container.insetBy(dx: 8, dy: 8).contains(corner), "\(corner)")
            XCTAssertGreaterThanOrEqual(corner.minY, 146, "下方放不下时翻到锚点上方")
            let left = InAppMenu.frame(size: size, anchor: NSRect(x: 90, y: 500, width: 24, height: 26), container: container)
            XCTAssertEqual(left.minX, 108)
        }
    }

    /// 打开后以子窗口显示在主窗口内；点选动作前先关闭。
    func testMenuOpensAsChildWindowAndClosesOnSelect() async throws {
        try await MainActor.run {
            try fixture { store, list, source, _, todos in
                let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
                // 代码创建的 NSWindow 默认关闭即释放，ARC 再释放一次会崩溃。
                window.isReleasedWhenClosed = false
                defer { window.close() }
                window.contentView = list.view
                window.orderFront(nil)
                list.reload()
                let button = NSButton(frame: NSRect(x: 640, y: 20, width: 24, height: 26))
                list.view.addSubview(button)
                let menu = list.headingMenu(source.headings[0].id, anchor: button)
                menu.show(from: button)
                XCTAssertTrue(menu.isOpen)
                XCTAssertTrue(InAppMenu.current === menu)
                let child = try XCTUnwrap(window.childWindows?.first)
                XCTAssertTrue(window.frame.contains(child.frame), "菜单不越出主窗口")
                XCTAssertEqual(child.appearance?.name, .darkAqua)
                menu.perform(title: "存档")
                XCTAssertFalse(menu.isOpen)
                XCTAssertNil(InAppMenu.current)
                XCTAssertTrue(window.childWindows?.isEmpty ?? true)
                XCTAssertEqual(store.todo(todos[0].id)?.status, .completed)
            }
        }
    }

    @MainActor private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
}
