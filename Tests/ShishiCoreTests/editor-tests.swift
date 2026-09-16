import AppKit
import XCTest
import ShishiCore
@testable import Shishi

final class EditorTests: XCTestCase {
    @MainActor private func fixture(_ body: (TaskStore, URL) throws -> Void) throws {
        _ = NSApplication.shared
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shishi-editor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("db.json")
        try body(TaskStore(fileURL: url), url)
    }

    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }

    @MainActor private func control<T: NSView>(_ type: T.Type, in view: NSView, label: String) throws -> T {
        try XCTUnwrap(descendants(view).compactMap { $0 as? T }.first { $0.accessibilityLabel() == label })
    }

    @MainActor private func button(_ title: String, in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(view).compactMap { $0 as? NSButton }.first { $0.title == title })
    }

    @MainActor private func select(_ title: String, in popup: NSPopUpButton) {
        popup.selectItem(withTitle: title)
        if let action = popup.action { _ = popup.sendAction(action, to: popup.target) }
    }

    func testScheduleMenuSelectionPersistsEachMeaning() async throws {
        try await MainActor.run {
            try fixture { store, url in
                let choices: [(String, Schedule)] = [("收件箱", .inbox), ("随时", .anytime), ("某天", .someday), ("指定日期", .dated)]
                let date = Date(timeIntervalSince1970: 1_800_000_000)
                for (label, expected) in choices {
                    let task = Todo(title: label, schedule: expected, startDate: expected == .dated ? date : nil)
                    let editor = TaskEditorController(store: store, todo: task, isNew: true)
                    editor.loadView()
                    let popup = try control(NSPopUpButton.self, in: editor.view, label: "安排")
                    XCTAssertEqual(popup.itemTitles, choices.map { $0.0 })
                    XCTAssertEqual(popup.titleOfSelectedItem, label)
                    // 从另一种安排切换回来，验证菜单动作与保存映射，而非只检查初始值。
                    select(label == "收件箱" ? "随时" : "收件箱", in: popup)
                    select(label, in: popup)
                    if expected == .dated {
                        try control(OptionalDateField.self, in: editor.view, label: "开始日期（取消勾选可清除）").set(date)
                    }
                    var finished: [UUID?] = []
                    editor.onFinish = { finished.append($0) }
                    editor.saveDraft()
                    XCTAssertEqual(finished, [task.id])
                    XCTAssertEqual(store.todo(task.id)?.schedule, expected)
                    XCTAssertEqual(store.todo(task.id)?.startDate, expected == .dated ? date : nil)
                    XCTAssertEqual(TaskStore(fileURL: url).todo(task.id)?.schedule, expected)
                }
            }
        }
    }

    func testSomedayShortcutClearsStartAndEveningButKeepsDeadline() async throws {
        try await MainActor.run {
            try fixture { store, _ in
                let date = Date(timeIntervalSince1970: 1_800_000_000)
                let task = Todo(title: "稍后处理", schedule: .dated, startDate: date, deadline: date, evening: true)
                let editor = TaskEditorController(store: store, todo: task, isNew: true)
                editor.loadView()
                try button("某天", in: editor.view).performClick(nil)
                editor.saveDraft()
                let saved = try XCTUnwrap(store.todo(task.id))
                XCTAssertEqual(saved.schedule, .someday)
                XCTAssertNil(saved.startDate)
                XCTAssertFalse(saved.evening)
                XCTAssertEqual(saved.deadline, date)
            }
        }
    }

    func testDatedWithoutStartRejectsSaveAndCanRecover() async throws {
        try await MainActor.run {
            try fixture { store, url in
                let task = Todo(title: "选择日期")
                let editor = TaskEditorController(store: store, todo: task, isNew: true)
                editor.loadView()
                select("指定日期", in: try control(NSPopUpButton.self, in: editor.view, label: "安排"))
                var finished: [UUID?] = []
                editor.onFinish = { finished.append($0) }
                editor.saveDraft()
                XCTAssertTrue(finished.isEmpty)
                XCTAssertTrue(store.todos.isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
                XCTAssertTrue(editor.feedback.stringValue.contains("开始日期"))
                try control(OptionalDateField.self, in: editor.view, label: "开始日期（取消勾选可清除）").set(Date())
                editor.saveDraft()
                XCTAssertEqual(finished, [task.id])
                XCTAssertEqual(store.todo(task.id)?.schedule, .dated)
            }
        }
    }

    func testWhitespaceTitlesRejectAllThreeEditors() async throws {
        try await MainActor.run {
            try fixture { store, url in
                let editors: [(EditorFormController, String)] = [
                    (TaskEditorController(store: store, todo: Todo(title: "任务"), isNew: true), "新任务"),
                    (ProjectEditorController(store: store, project: Project(title: "项目")), "项目名称"),
                    (AreaEditorController(store: store, area: Area(title: "区域")), "区域名称")
                ]
                for (editor, label) in editors {
                    editor.loadView()
                    try control(NSTextField.self, in: editor.view, label: label).stringValue = " \n\t "
                    var called = false
                    if let task = editor as? TaskEditorController { task.onFinish = { _ in called = true } }
                    if let project = editor as? ProjectEditorController { project.onFinish = { _ in called = true } }
                    if let area = editor as? AreaEditorController { area.onFinish = { _ in called = true } }
                    editor.saveDraft()
                    XCTAssertFalse(called)
                    XCTAssertFalse(editor.feedback.stringValue.isEmpty)
                }
                XCTAssertEqual(store.snapshot, Snapshot())
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    func testCancelDiscardsChangesInAllThreeEditorsWithoutWriting() async throws {
        try await MainActor.run {
            try fixture { store, url in
                let task = Todo(title: "原任务"), project = Project(title: "原项目"), area = Area(title: "原区域")
                XCTAssertTrue(store.save(task)); XCTAssertTrue(store.saveProject(project)); XCTAssertTrue(store.saveArea(area))
                let before = store.snapshot
                let bytes = try Data(contentsOf: url)
                let taskEditor = TaskEditorController(store: store, todo: task, isNew: false)
                let projectEditor = ProjectEditorController(store: store, project: project)
                let areaEditor = AreaEditorController(store: store, area: area)
                var finished: [UUID?] = []
                taskEditor.onFinish = { finished.append($0) }
                projectEditor.onFinish = { finished.append($0) }
                areaEditor.onFinish = { finished.append($0) }
                let editors: [(EditorFormController, String)] = [(taskEditor, "任务标题"), (projectEditor, "项目名称"), (areaEditor, "区域名称")]
                for (editor, label) in editors {
                    editor.loadView()
                    try control(NSTextField.self, in: editor.view, label: label).stringValue = "未保存修改"
                    editor.cancelDraft()
                }
                XCTAssertEqual(finished.count, 3)
                XCTAssertTrue(finished.allSatisfy { $0 == nil })
                XCTAssertEqual(store.snapshot, before)
                XCTAssertEqual(try Data(contentsOf: url), bytes)
                XCTAssertFalse(store.canRedo)
            }
        }
    }

    func testChecklistAddToggleRemoveAndPersist() async throws {
        try await MainActor.run {
            try fixture { store, url in
                let keep = ChecklistItem(title: "保留"), remove = ChecklistItem(title: "移除")
                let task = Todo(title: "清单任务", checklist: [keep, remove])
                let editor = TaskEditorController(store: store, todo: task, isNew: true)
                editor.loadView()
                let fields = descendants(editor.view).compactMap { $0 as? NSTextField }.filter { $0.accessibilityLabel() == "清单内容" }
                let keepField = try XCTUnwrap(fields.first { $0.stringValue == "保留" })
                let keepLine = try XCTUnwrap(keepField.superview)
                let check = try control(NSButton.self, in: keepLine, label: "清单项完成状态")
                check.performClick(nil)
                keepField.stringValue = " 保留并完成 "
                let removeLine = try XCTUnwrap(fields.first { $0.stringValue == "移除" }?.superview)
                try button("移除", in: removeLine).performClick(nil)
                try button("添加清单项", in: editor.view).performClick(nil)
                let added = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "清单内容" && $0.stringValue.isEmpty })
                added.stringValue = "新增项"
                XCTAssertTrue(store.todos.isEmpty)
                editor.saveDraft()
                let saved = try XCTUnwrap(TaskStore(fileURL: url).todo(task.id))
                XCTAssertEqual(saved.checklist.map(\.title), ["保留并完成", "新增项"])
                XCTAssertEqual(saved.checklist.map(\.completed), [true, false])
                XCTAssertEqual(saved.checklist.first?.id, keep.id)
                XCTAssertFalse(saved.checklist.contains { $0.id == remove.id })
            }
        }
    }

    func testBlankChecklistItemRejectsUntilRemoved() async throws {
        try await MainActor.run {
            try fixture { store, url in
                let task = Todo(title: "空白清单项")
                let editor = TaskEditorController(store: store, todo: task, isNew: true)
                editor.loadView()
                try button("添加清单项", in: editor.view).performClick(nil)
                try control(NSTextField.self, in: editor.view, label: "清单内容").stringValue = " \n "
                var finished: [UUID?] = []
                editor.onFinish = { finished.append($0) }
                editor.saveDraft()
                XCTAssertTrue(finished.isEmpty)
                XCTAssertTrue(store.todos.isEmpty)
                XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
                XCTAssertTrue(editor.feedback.stringValue.contains("清单内容不能为空"))
                try button("移除", in: editor.view).performClick(nil)
                editor.saveDraft()
                XCTAssertEqual(finished, [task.id])
                XCTAssertEqual(store.todo(task.id)?.checklist, [])
            }
        }
    }

    func testTaskAndProjectNotesAllowUndoAndPreserveMultilineInput() async throws {
        try await MainActor.run {
            try fixture { store, _ in
                let task = Todo(title: "任务备注"), project = Project(title: "项目说明")
                let editors: [EditorFormController] = [TaskEditorController(store: store, todo: task, isNew: true), ProjectEditorController(store: store, project: project)]
                for editor in editors {
                    editor.loadView()
                    let text = try XCTUnwrap(descendants(editor.view).compactMap { $0 as? NSTextView }.first)
                    XCTAssertTrue(text.allowsUndo)
                    XCTAssertFalse(text.isRichText)
                    text.string = "第一行\n第二行"
                    editor.saveDraft()
                }
                XCTAssertEqual(store.todo(task.id)?.notes, "第一行\n第二行")
                XCTAssertEqual(store.projects.first { $0.id == project.id }?.notes, "第一行\n第二行")
            }
        }
    }
}
