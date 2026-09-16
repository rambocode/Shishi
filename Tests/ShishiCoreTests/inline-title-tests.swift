import AppKit
import XCTest
import ShishiCore
@testable import Shishi

/// 标题原地编辑：项目标题与标题分组双击即改，输入停顿自动保存，Escape 还原。
final class InlineTitleTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor private func window(for view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }

    /// 模拟一次真实输入：替换字段编辑器内容，触发与键入相同的变更通知。
    @MainActor private func type(_ text: String, into field: NSTextField) throws {
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    func testLiveSaveReturnCommitAndEscapeRevert() async throws {
        try await MainActor.run {
            _ = NSApplication.shared
            let field = InlineTitleField(title: "原标题")
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
            field.frame = NSRect(x: 0, y: 40, width: 300, height: 24)
            host.addSubview(field)
            let window = window(for: host)
            defer { window.close() }
            var saved: [String] = []
            field.onSave = { saved.append($0); return true }
            field.beginEditing()
            XCTAssertFalse(field.isEditingTitle, "未开启改名时双击无效")
            field.isRenameEnabled = true
            field.beginEditing()
            XCTAssertTrue(field.isEditable)
            try type("新标题", into: field)
            RunLoop.main.run(until: Date().addingTimeInterval(InlineTitleField.saveDelay + 0.3))
            XCTAssertEqual(saved, ["新标题"], "停顿后实时保存")
            try type("再改一次", into: field)
            // Escape 撤回实时保存过的中间结果。
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
            XCTAssertTrue(field.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))))
            XCTAssertEqual(saved.last, "原标题")
            XCTAssertEqual(field.stringValue, "原标题")
            XCTAssertFalse(field.isEditable)

            field.beginEditing()
            try type("  最终标题  ", into: field)
            let editor2 = try XCTUnwrap(field.currentEditor() as? NSTextView)
            XCTAssertTrue(field.control(field, textView: editor2, doCommandBy: #selector(NSResponder.insertNewline(_:))))
            XCTAssertEqual(saved.last, "最终标题")
            XCTAssertEqual(field.stringValue, "最终标题")

            let count = saved.count
            field.beginEditing()
            try type("   ", into: field)
            field.commitEditing()
            XCTAssertEqual(saved.count, count, "空标题不保存")
            XCTAssertEqual(field.stringValue, "最终标题")
        }
    }

    @MainActor private func projectFixture(_ body: (TaskListController, TaskStore, Project) throws -> Void) throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("db.json")
        let project = Project(title: "报销", headings: [Heading(title: "国控项目", order: 0), Heading(title: "6月报销", order: 1)])
        try SnapshotFile(url: url).write(Snapshot(projects: [project]))
        let store = TaskStore(fileURL: url)
        let list = TaskListController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = list
        window.setContentSize(NSSize(width: 900, height: 650))
        defer { window.contentViewController = nil; window.close() }
        list.route = .project(project.id)
        list.view.layoutSubtreeIfNeeded()
        try body(list, store, project)
    }

    func testProjectTitleRenamesInPlace() async throws {
        try await MainActor.run {
            try projectFixture { list, store, _ in
                let title = try XCTUnwrap(descendants(list.view).compactMap { $0 as? InlineTitleField }.first { $0.stringValue == "报销" && !($0.superview is ListHeadingView) })
                XCTAssertTrue(title.isRenameEnabled)
                title.beginEditing()
                try type("报销 2026", into: title)
                title.commitEditing()
                XCTAssertEqual(store.projects[0].title, "报销 2026")
                XCTAssertEqual(title.stringValue, "报销 2026")
            }
        }
    }

    /// 选中标题分组：浅蓝底由行视图绘制，标题视图收起“＋”，与参考图一致。
    func testSelectedHeadingRowUsesLightBlueStyle() async throws {
        try await MainActor.run {
            try projectFixture { list, _, _ in
                let table = try XCTUnwrap(descendants(list.view).compactMap { $0 as? NSTableView }.first)
                let row = try XCTUnwrap((0..<table.numberOfRows).last { table.view(atColumn: 0, row: $0, makeIfNecessary: true) is ListHeadingView })
                table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                let rowView = try XCTUnwrap(table.rowView(atRow: row, makeIfNecessary: true) as? TaskListRowView)
                let heading = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ListHeadingView)
                XCTAssertTrue(rowView.isHeadingRow)
                XCTAssertTrue(heading.isRowSelected)
                let add = descendants(heading).compactMap { $0 as? NSButton }.first { $0.toolTip == "在这个标题下新建待办" }
                XCTAssertEqual(add?.isHidden, true)
                // 上一行标题的底部分隔线紧贴选中底，也要隐藏。
                let aboveRow = try XCTUnwrap((0..<row).last { table.view(atColumn: 0, row: $0, makeIfNecessary: true) is ListHeadingView })
                if aboveRow == row - 1 {
                    let above = try XCTUnwrap(table.view(atColumn: 0, row: aboveRow, makeIfNecessary: true) as? ListHeadingView)
                    XCTAssertTrue(above.isNextRowSelected)
                    table.deselectAll(nil)
                    XCTAssertFalse(above.isNextRowSelected)
                }
                table.deselectAll(nil)
                XCTAssertFalse(heading.isRowSelected)
                XCTAssertEqual(add?.isHidden, false)
            }
        }
    }

    func testHeadingRowRenamesInPlaceWithoutRebuildingDuringTyping() async throws {
        try await MainActor.run {
            try projectFixture { list, store, _ in
                let table = try XCTUnwrap(descendants(list.view).compactMap { $0 as? NSTableView }.first)
                let row = try XCTUnwrap((0..<table.numberOfRows).first { table.view(atColumn: 0, row: $0, makeIfNecessary: true) is ListHeadingView })
                let view = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ListHeadingView)
                XCTAssertTrue(view.titleField.isRenameEnabled)
                view.titleField.beginEditing()
                try type("国控项目二期", into: view.titleField)
                RunLoop.main.run(until: Date().addingTimeInterval(InlineTitleField.saveDelay + 0.3))
                XCTAssertEqual(store.projects[0].headings[0].title, "国控项目二期", "输入停顿后实时保存")
                // 实时保存触发的刷新被延后，输入框仍是同一个、仍在编辑。
                XCTAssertTrue(table.view(atColumn: 0, row: row, makeIfNecessary: false) === view)
                XCTAssertTrue(view.titleField.isEditingTitle)
                view.titleField.commitEditing()
                let rebuilt = try XCTUnwrap(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? ListHeadingView)
                XCTAssertEqual(rebuilt.titleField.stringValue, "国控项目二期")
            }
        }
    }
}
