import AppKit
import ShishiCore

/// 项目页的原地编辑：标题下的备注直接输入、停顿自动保存，失焦或离开页面立即保存；
/// 以及项目标题、标题分组双击改名时的刷新协调。
extension TaskListController {
    /// 输入节流间隔；太短会让每个字都进撤销栈，太长则关窗前更容易有未保存内容。
    static let projectNotesSaveDelay: TimeInterval = 0.6

    /// 记下最新内容并重新计时；项目 ID 在输入时就固定，切到别的项目也不会写错。
    func projectNotesChanged(_ text: String) {
        guard case .project(let id) = route else { return }
        pendingProjectNotes = (id, text)
        projectNotesSaveTimer?.invalidate()
        // 用 RunLoop 定时器而非主队列延时：common 模式下输入、滚动期间也会按时触发。
        let timer = Timer(timeInterval: Self.projectNotesSaveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.flushProjectNotes() }
        }
        RunLoop.main.add(timer, forMode: .common)
        projectNotesSaveTimer = timer
    }

    /// 记录正在改名的标题；结束后补做被延后的刷新。
    func titleEditingChanged(_ field: InlineTitleField?, editing: Bool) {
        if editing { editingTitleField = field; return }
        guard editingTitleField === field else { return }
        editingTitleField = nil
        if titleReloadPending { titleReloadPending = false; reload() }
    }

    /// 立即写入待保存的备注；内容与库里一致时不写，避免产生空撤销步骤。
    func flushProjectNotes() {
        projectNotesSaveTimer?.invalidate()
        projectNotesSaveTimer = nil
        guard let pending = pendingProjectNotes else { return }
        pendingProjectNotes = nil
        guard var project = store.projects.first(where: { $0.id == pending.id }), project.notes != pending.text else { return }
        project.notes = pending.text
        store.saveProject(project)
    }
}
