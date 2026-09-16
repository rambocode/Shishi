import AppKit
import XCTest
import ShishiCore
@testable import Shishi

/// 侧栏区域与项目改名：双击直接在行内编辑，不再弹出编辑器窗口。
final class SidebarRenameTests: XCTestCase {
    @MainActor private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    /// 取表格自己持有的那份 cell，改名操作与断言必须落在同一个控件上。
    @MainActor private func field(for title: String, in sidebar: SidebarController) throws -> NSTextField {
        let table = try XCTUnwrap(allViews(sidebar.view).compactMap { $0 as? NSTableView }.first)
        for row in 0..<table.numberOfRows {
            let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView
            if let label = cell?.textField, label.stringValue == title { return label }
        }
        throw XCTSkip("没有找到区域行：" + title)
    }

    @MainActor private func makeStore(_ area: Area) throws -> (TaskStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("db.json")
        try SnapshotFile(url: url).write(Snapshot(areas: [area]))
        return (TaskStore(fileURL: url), folder)
    }

    @MainActor private func endEditing(_ sidebar: SidebarController, field: NSTextField) {
        sidebar.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    }

    func testDoubleClickRenameWritesNewTitleWithoutEditorWindow() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let area = Area(title: "个人")
            let (store, folder) = try makeStore(area)
            defer { try? FileManager.default.removeItem(at: folder) }
            let sidebar = SidebarController(store: store)
            _ = sidebar.view
            sidebar.beginRename(.area(area.id))
            let label = try field(for: "个人", in: sidebar)
            XCTAssertTrue(label.isEditable, "双击后应直接可编辑")
            label.stringValue = "  私人事务  "
            endEditing(sidebar, field: label)
            XCTAssertEqual(store.areas.first?.title, "私人事务")
            XCTAssertFalse(label.isEditable, "结束后恢复为普通标签")
        }
    }

    func testEmptyAndUnchangedTitlesKeepOriginalArea() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let area = Area(title: "工作")
            let (store, folder) = try makeStore(area)
            defer { try? FileManager.default.removeItem(at: folder) }
            let sidebar = SidebarController(store: store)
            _ = sidebar.view
            sidebar.beginRename(.area(area.id))
            var label = try field(for: "工作", in: sidebar)
            label.stringValue = "   "
            endEditing(sidebar, field: label)
            XCTAssertEqual(store.areas.first?.title, "工作")
            sidebar.beginRename(.area(area.id))
            label = try field(for: "工作", in: sidebar)
            endEditing(sidebar, field: label)
            XCTAssertEqual(store.areas.first?.title, "工作")
        }
    }

    /// Return 必须提交改名：侧栏标签默认多行，字段编辑器里回车曾经只换行。
    func testReturnCommitsRenameAndUsesSingleLineEditing() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let area = Area(title: "旧名字")
            let (store, folder) = try makeStore(area)
            defer { try? FileManager.default.removeItem(at: folder) }
            let sidebar = SidebarController(store: store)
            _ = sidebar.view
            sidebar.beginRename(.area(area.id))
            let label = try field(for: "旧名字", in: sidebar)
            XCTAssertTrue(label.usesSingleLineMode)
            label.stringValue = "新名字"
            let handled = sidebar.control(label, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:)))
            XCTAssertTrue(handled)
            XCTAssertEqual(store.areas.first?.title, "新名字")
            XCTAssertFalse(label.usesSingleLineMode, "结束后恢复标签的换行设置")
        }
    }

    /// 项目与区域共用同一套行内改名；项目保存走 ProjectOperations 校验。
    func testProjectRenameSavesAndEscapeKeepsOriginal() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let area = Area(title: "区域")
            let project = Project(title: "旧项目", areaID: area.id)
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: url).write(Snapshot(projects: [project], areas: [area]))
            let store = TaskStore(fileURL: url)
            let sidebar = SidebarController(store: store)
            _ = sidebar.view
            sidebar.beginRename(.project(project.id))
            var label = try field(for: "旧项目", in: sidebar)
            XCTAssertTrue(label.isEditable)
            label.stringValue = "新项目"
            XCTAssertTrue(sidebar.control(label, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
            XCTAssertEqual(store.projects.first?.title, "新项目")
            XCTAssertEqual(store.projects.first?.areaID, area.id, "改名不改变项目的其它属性")
            sidebar.beginRename(.project(project.id))
            label = try field(for: "新项目", in: sidebar)
            label.stringValue = "放弃"
            XCTAssertTrue(sidebar.control(label, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            XCTAssertEqual(store.projects.first?.title, "新项目")
        }
    }

    func testEscapeCancelsRenameAndKeepsOriginalTitle() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let area = Area(title: "家庭")
            let (store, folder) = try makeStore(area)
            defer { try? FileManager.default.removeItem(at: folder) }
            let sidebar = SidebarController(store: store)
            _ = sidebar.view
            sidebar.beginRename(.area(area.id))
            let label = try field(for: "家庭", in: sidebar)
            label.stringValue = "放弃的名字"
            let handled = sidebar.control(label, textView: NSTextView(), doCommandBy: #selector(NSResponder.cancelOperation(_:)))
            XCTAssertTrue(handled)
            XCTAssertEqual(store.areas.first?.title, "家庭")
            XCTAssertFalse(label.isEditable)
        }
    }
}
