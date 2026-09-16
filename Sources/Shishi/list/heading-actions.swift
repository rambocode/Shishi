import AppKit
import ShishiCore

/// 项目内标题分组「…」菜单：存档、移动…、转换为项目…、删除。
/// 使用深色应用内菜单（InAppMenu），始终显示在窗口内。
/// 每个动作只捕获标题 ID，执行时重新读取最新快照；写入失败由 Store 的失败通知统一呈现。
extension TaskListController {

    /// 从标题行的「…」按钮弹出菜单。
    func showHeadingMenu(_ headingID: UUID, from sender: NSView) {
        guard case .project = route, finishInlineEditing() else { return }
        headingMenu(headingID, anchor: sender).show(from: sender)
    }

    /// 构建标题菜单；anchor 供「移动…」在菜单关闭后在同一位置弹出项目列表。
    func headingMenu(_ headingID: UUID, anchor: NSView) -> InAppMenu {
        InAppMenu(entries: [
            .item(title: "存档", icon: "checkmark.rectangle.stack") { [weak self] in self?.archiveHeading(headingID) },
            .separator,
            .item(title: "移动…", icon: "arrow.right") { [weak self, weak anchor] in
                guard let self, let anchor, anchor.window != nil else { return }
                self.headingMoveMenu(headingID).show(from: anchor)
            },
            .item(title: "转换为项目…", icon: "arrow.up.forward.app") { [weak self] in self?.confirmConvertHeading(headingID) },
            .item(title: "删除", icon: "trash") { [weak self] in self?.trashHeading(headingID) }
        ])
    }

    func archiveHeading(_ headingID: UUID) {
        guard case .project(let projectID) = route, finishInlineEditing() else { return }
        store.applyHeadingOperation { try HeadingOperations.archive(headingID, in: projectID, snapshot: &$0) }
    }

    func trashHeading(_ headingID: UUID) {
        guard case .project(let projectID) = route, finishInlineEditing() else { return }
        store.applyHeadingOperation { try HeadingOperations.trash(headingID, in: projectID, snapshot: &$0) }
    }

    /// 标题连同待办移到目标项目；成功后跳到目标项目，让用户看到移动结果。
    @discardableResult
    func moveHeading(_ headingID: UUID, to targetID: UUID) -> Bool {
        guard case .project(let projectID) = route, finishInlineEditing() else { return false }
        guard store.applyHeadingOperation({ try HeadingOperations.move(headingID, from: projectID, to: targetID, snapshot: &$0) }) != nil else { return false }
        onNavigate?(.project(targetID))
        return true
    }

    /// 转换成功后打开新项目。
    @discardableResult
    func convertHeadingToProject(_ headingID: UUID) -> UUID? {
        guard case .project(let projectID) = route, finishInlineEditing() else { return nil }
        guard let id = store.applyHeadingOperation({ try HeadingOperations.convertToProject(headingID, in: projectID, snapshot: &$0) }) else { return nil }
        onNavigate?(.project(id))
        return id
    }

    /// 可移入的项目：除当前项目外所有开放项目，与待办的移动菜单同一过滤规则。
    func headingMoveMenu(_ headingID: UUID) -> InAppMenu {
        guard case .project(let projectID) = route else { return InAppMenu(entries: []) }
        let targets = store.projects.filter { $0.id != projectID && !$0.completed && $0.deletedAt == nil && ($0.status == nil || $0.status == .open) }
        if targets.isEmpty { return InAppMenu(entries: [.item(title: "没有其他项目", icon: nil, enabled: false) {}]) }
        return InAppMenu(entries: targets.map { project in
            .item(title: project.title, icon: "circle") { [weak self] in self?.moveHeading(headingID, to: project.id) }
        })
    }

    /// 转换会改变待办归属，先确认；确认框写明将移入新项目的待办数。
    private func confirmConvertHeading(_ headingID: UUID) {
        guard case .project(let projectID) = route, let window = view.window,
              let heading = store.projects.first(where: { $0.id == projectID })?.headings.first(where: { $0.id == headingID }) else { return }
        let count = store.todos.filter { $0.projectID == projectID && $0.headingID == headingID && Domain.deletionDate($0, in: store.snapshot) == nil }.count
        let alert = NSAlert()
        alert.messageText = "将“\(heading.title)”转换为项目？"
        alert.informativeText = count == 0 ? "将新建同名项目，并移除这个标题。" : "将新建同名项目，这个标题下的 \(count) 个待办会移到新项目中。"
        alert.addButton(withTitle: "转换"); alert.addButton(withTitle: "取消")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.convertHeadingToProject(headingID)
        }
    }
}
