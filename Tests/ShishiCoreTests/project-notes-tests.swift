import AppKit
import XCTest
import ShishiCore
@testable import Shishi

/// 项目页备注直接编辑：占位不入库、停顿后保存、离开页面立即保存、关闭的项目只读。
final class ProjectNotesTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    @MainActor private func fixture(_ projects: [Project], body: (TaskListController, TaskStore, BoundedNotesView) throws -> Void) throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("db.json")
        try SnapshotFile(url: url).write(Snapshot(projects: projects))
        let store = TaskStore(fileURL: url)
        let list = TaskListController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = list
        window.setContentSize(NSSize(width: 900, height: 650))
        defer { window.contentViewController = nil; window.close() }
        list.route = .project(projects[0].id)
        list.view.layoutSubtreeIfNeeded()
        let notes = try XCTUnwrap(descendants(list.view).compactMap { $0 as? BoundedNotesView }.first)
        try body(list, store, notes)
    }

    func testEmptyNotesShowPlaceholderWithoutSavingIt() async throws {
        try await MainActor.run {
            let project = Project(title: "报销")
            try fixture([project]) { _, store, notes in
                XCTAssertTrue(notes.isNotesEditable)
                XCTAssertEqual(notes.stringValue, "", "“备注”只是占位，不能作为正文")
                XCTAssertEqual(notes.placeholder, "备注")
                XCTAssertEqual(store.projects[0].notes, "")
                let document = try XCTUnwrap(notes.documentView as? NSTextView)
                XCTAssertTrue(document.isEditable)
                let label = try XCTUnwrap(descendants(notes).compactMap { $0 as? NSTextField }.first { $0.stringValue == "备注" })
                XCTAssertFalse(label.isHidden)
                XCTAssertGreaterThan(label.frame.width, 10, "占位文字要有实际宽度，否则界面上看不到")
            }
        }
    }

    func testTypingSavesAfterPauseAndFlushOnLeave() async throws {
        try await MainActor.run {
            let project = Project(title: "报销"), other = Project(title: "其它")
            try fixture([project, other]) { list, store, _ in
                list.projectNotesChanged("第一段")
                XCTAssertEqual(store.projects[0].notes, "", "输入中先节流，不是每个字都写库")
                // 等待节流到期后自动保存。
                RunLoop.main.run(until: Date().addingTimeInterval(TaskListController.projectNotesSaveDelay + 0.3))
                XCTAssertEqual(store.projects[0].notes, "第一段")
                list.projectNotesChanged("第一段\n第二段")
                // 切换页面前必须落盘，不能丢最后一次输入。
                list.route = .project(other.id)
                XCTAssertEqual(store.projects.first { $0.id == project.id }?.notes, "第一段\n第二段")
                XCTAssertEqual(store.projects.first { $0.id == other.id }?.notes, "", "保存目标是输入时的项目")
            }
        }
    }

    /// 真实输入链路：文本视图里打字 → 回调 → 失焦立即保存。
    func testTypingInNotesViewSavesOnEndEditing() async throws {
        try await MainActor.run {
            let project = Project(title: "报销")
            try fixture([project]) { list, store, notes in
                let document = try XCTUnwrap(notes.documentView as? NSTextView)
                XCTAssertTrue(list.view.window?.makeFirstResponder(document) ?? false)
                document.insertText("发票已提交", replacementRange: document.selectedRange())
                XCTAssertTrue(notes.isEditingNotes)
                // 刷新列表不能覆盖正在输入的文字。
                list.reload()
                XCTAssertEqual(notes.stringValue, "发票已提交")
                XCTAssertTrue(list.view.window?.makeFirstResponder(nil) ?? false)
                XCTAssertEqual(store.projects[0].notes, "发票已提交")
            }
        }
    }

    func testClosedProjectNotesAreReadOnly() async throws {
        try await MainActor.run {
            var project = Project(title: "已完成")
            project.completed = true; project.status = .completed
            try fixture([project]) { _, _, notes in
                XCTAssertFalse(notes.isNotesEditable)
                XCTAssertEqual(notes.placeholder, "")
            }
        }
    }
}
