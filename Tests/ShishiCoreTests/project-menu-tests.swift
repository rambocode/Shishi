import AppKit
import XCTest
import ShishiCore
@testable import Shishi

final class ProjectMenuTests: XCTestCase {
    func testMenuActionsAreRetainedAndCompletionUsesLatestProject() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = TaskStore(fileURL: folder.appendingPathComponent("db.json"))
            var project = Project(title: "项目")
            XCTAssertTrue(store.saveProject(project))
            let controller = ProjectActionsController(store: store)
            var changes = 0; controller.onChanged = { changes += 1 }
            let menu = controller.buildMenu(projectID: project.id)
            let actions = menu.items.filter { !$0.isSeparatorItem }
            XCTAssertEqual(actions.count, 9)
            XCTAssertEqual(menu.items.count, 10)
            XCTAssertTrue(menu.items[4].isSeparatorItem)
            XCTAssertEqual(actions.map(\.title), ["完成项目", "时间", "添加标签", "添加截止日期", "移动", "重复…", "复制项目", "删除项目", "分享…"])
            XCTAssertTrue(actions.allSatisfy { $0.image != nil && $0.target != nil && $0.action != nil && $0.representedObject != nil })
            project.notes = "菜单打开后的修改"; XCTAssertTrue(store.saveProject(project))
            try run(menu.items[0])
            XCTAssertEqual(store.projects.first?.notes, project.notes)
            XCTAssertEqual(store.projects.first?.status, .completed)
            XCTAssertEqual(changes, 1)
            let reopened = controller.buildMenu(projectID: project.id)
            XCTAssertEqual(reopened.items[0].title, "重新打开项目")
            try run(reopened.items[0])
            XCTAssertEqual(store.projects.first?.status, .open)
            XCTAssertEqual(store.projects.first?.completed, false)
        }
    }

    func testDateAndMoveOnlyChangeTheirFieldsAndTrashDisablesMenu() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let area = Area(title: "区域")
            let project = Project(title: "项目", notes: "保留", tags: ["标签"])
            let url = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: url).write(Snapshot(projects: [project], areas: [area]))
            let store = TaskStore(fileURL: url)
            let controller = ProjectActionsController(store: store)
            XCTAssertTrue(controller.applyDate(.evening, projectID: project.id, deadline: false))
            XCTAssertEqual(store.projects[0].evening, true)
            XCTAssertEqual(store.projects[0].schedule, .dated)
            let start = store.projects[0].startDate
            let deadline = Date(timeIntervalSince1970: 1_800_000_000)
            XCTAssertTrue(controller.applyDate(.date(deadline), projectID: project.id, deadline: true))
            XCTAssertEqual(store.projects[0].startDate, start)
            XCTAssertEqual(store.projects[0].evening, true)
            XCTAssertTrue(controller.move(project.id, areaID: area.id))
            XCTAssertEqual(store.projects[0].areaID, area.id)
            XCTAssertTrue(controller.move(project.id, areaID: nil))
            XCTAssertNil(store.projects[0].areaID)
            XCTAssertFalse(controller.move(project.id, areaID: UUID()))
            XCTAssertEqual(store.projects[0].notes, "保留")
            XCTAssertEqual(store.projects[0].tags, ["标签"])
            store.trashProject(project.id)
            XCTAssertTrue(controller.buildMenu(projectID: project.id).items.filter { !$0.isSeparatorItem }.allSatisfy { !$0.isEnabled })
            XCTAssertFalse(controller.applyDate(.clear, projectID: project.id, deadline: true))
            XCTAssertNil(controller.sharingText(projectID: project.id))
            XCTAssertTrue(controller.buildMenu(projectID: UUID()).items.isEmpty)
        }
    }

    func testCopyNavigatesAndSharingIncludesGroupedChecklistWithoutLaunchingServices() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let heading = Heading(title: "分组")
            let project = Project(title: "项目", notes: "项目备注", headings: [heading])
            let task = Todo(title: "任务", notes: "任务备注", projectID: project.id, headingID: heading.id,
                            checklist: [ChecklistItem(title: "清单项")])
            let hidden = Todo(title: "不分享", projectID: project.id, deletedAt: Date())
            let url = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: url).write(Snapshot(todos: [task, hidden], projects: [project]))
            let store = TaskStore(fileURL: url)
            let controller = ProjectActionsController(store: store)
            let text = try XCTUnwrap(controller.sharingText(projectID: project.id))
            for word in ["项目", "项目备注", "分组", "任务备注", "清单项"] { XCTAssertTrue(text.contains(word)) }
            XCTAssertFalse(text.contains("不分享"))
            var route: Route?; controller.onNavigate = { route = $0 }
            let copy = try XCTUnwrap(controller.buildMenu(projectID: project.id).items.first { $0.title == "复制项目" })
            try run(copy)
            guard case .project(let id) = route else { return XCTFail("复制应导航到新项目") }
            XCTAssertNotEqual(id, project.id)
            XCTAssertEqual(store.projects.count, 2)
            let alert = controller.deletionAlert(project)
            XCTAssertEqual(alert.buttons.map(\.title), ["取消", "删除项目"])
            XCTAssertTrue(alert.informativeText.contains("不会被永久删除"))
        }
    }

    func testRepeatEditorValidatesAndKeepsDraftUntilExplicitSave() async throws {
        try await MainActor.run {
            let editor = ProjectRepeatEditor(rule: RepeatRule(unit: .week, interval: 2, afterCompletion: true))
            var saved: [RepeatRule?] = []
            editor.onSave = { saved.append($0); return false }
            let controls = descendants(editor.view)
            let popup = try XCTUnwrap(controls.compactMap { $0 as? NSPopUpButton }.first)
            let input = try XCTUnwrap(controls.compactMap { $0 as? NSTextField }.first { $0.isEditable })
            let save = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "完成" })
            XCTAssertTrue(saved.isEmpty)
            input.stringValue = "0"; save.performClick(nil); XCTAssertTrue(saved.isEmpty)
            input.stringValue = "3"; save.performClick(nil)
            XCTAssertEqual(saved[0], RepeatRule(unit: .week, interval: 3, afterCompletion: true))
            popup.selectItem(at: 0); save.performClick(nil)
            XCTAssertEqual(saved.count, 2); XCTAssertNil(saved[1])
        }
    }

    func testSharingExcludesDeletedHeadingDescendantsAndInternalRepeatTemplates() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let deletedHeading = Heading(title: "隐藏分组", deletedAt: Date(), notes: "隐藏分组备注")
            let visibleHeading = Heading(title: "可见分组")
            let project = Project(title: "项目", headings: [deletedHeading, visibleHeading])
            let deletedDescendant = Todo(title: "隐藏分组任务", notes: "隐藏任务备注", projectID: project.id,
                                         headingID: deletedHeading.id, checklist: [ChecklistItem(title: "隐藏清单")])
            let templateSource = SourceInfo(provider: "Things", identifier: "template", metadata: ["repeatTemplate": "true"])
            let template = Todo(title: "隐藏重复模板", notes: "模板备注", projectID: project.id,
                                checklist: [ChecklistItem(title: "模板清单")], source: templateSource)
            let groupedTemplate = Todo(title: "分组内部模板", projectID: project.id,
                                       headingID: visibleHeading.id, source: templateSource)
            let visible = Todo(title: "可见任务", projectID: project.id, headingID: visibleHeading.id)
            let instance = Todo(title: "可见重复实例", projectID: project.id,
                                source: SourceInfo(provider: "Things", identifier: "instance", metadata: ["repeatTemplate": "false"]))
            let url = folder.appendingPathComponent("db.json")
            try SnapshotFile(url: url).write(Snapshot(todos: [deletedDescendant, template, groupedTemplate, visible, instance], projects: [project]))
            let store = TaskStore(fileURL: url)
            let controller = ProjectActionsController(store: store)
            XCTAssertNil(deletedDescendant.deletedAt)
            XCTAssertNotNil(Domain.deletionDate(deletedDescendant, in: store.snapshot))
            let text = try XCTUnwrap(controller.sharingText(projectID: project.id))
            for hidden in ["隐藏分组", "隐藏分组备注", "隐藏分组任务", "隐藏任务备注", "隐藏清单", "隐藏重复模板", "模板备注", "模板清单", "分组内部模板"] {
                XCTAssertFalse(text.contains(hidden), "分享草稿泄露：\(hidden)")
            }
            for visible in ["可见分组", "可见任务", "可见重复实例"] { XCTAssertTrue(text.contains(visible)) }
        }
    }

    func testFailedWritePreservesProjectAndDoesNotPublishChange() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let url = folder.appendingPathComponent("db.json")
            let store = TaskStore(fileURL: url)
            let project = Project(title: "项目", notes: "保留")
            XCTAssertTrue(store.saveProject(project))
            let controller = ProjectActionsController(store: store)
            var changes = 0; controller.onChanged = { changes += 1 }
            // 仅将本测试的临时文件替换为目录，模拟保存目标无法写入。
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            XCTAssertFalse(controller.applyDate(.evening, projectID: project.id, deadline: false))
            XCTAssertEqual(store.projects.first, project)
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(changes, 0)
        }
    }

    @MainActor private func run(_ item: NSMenuItem) throws {
        let target = try XCTUnwrap(item.target as? NSObject)
        let action = try XCTUnwrap(item.action)
        XCTAssertTrue(target.responds(to: action)); target.perform(action, with: item)
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
