import AppKit
import ShishiCore

extension TaskListController {
    /// 新任务不会先写入Store；已有任务必须仍存在。切换编辑对象前先保存当前草稿。
    func beginEditing(_ todo: Todo, isNew: Bool) {
        _ = view
        if let editor = inlineEditor, editor.draft.id == todo.id { editor.focusTitle(); return }
        guard finishInlineEditing() else { return }
        guard isNew || store.todo(todo.id) != nil else { return }
        guard todo.deletedAt == nil else { onEditTask?(todo.id); return }
        let editor = InlineTaskEditorView(todo: todo, isNew: isNew, tagSuggestions: store.allTags, textSize: store.preferences.textSize)
        inlineEditor = editor
        editor.onHeightChanged = { [weak self] in self?.resizeInlineEditor() }
        editor.onChecklistSelectionChanged = { [weak self] in self?.updateTools() }
        editor.onSave = { [weak self] in self?.saveInlineEditing() }
        editor.onCancel = { [weak self] in self?.cancelInlineEditing() }
        editor.onDetails = { [weak self] in
            guard let self, self.saveInlineEditing() else { return }
            self.onEditTask?(todo.id)
        }
        reload(); selectTask(todo.id)
        view.layoutSubtreeIfNeeded()
        editor.focusTitle()
        onInlineEditingChanged?(true)
    }

    /// 导航、关窗和退出的统一边界。空白新建可丢弃；其余草稿必须保存成功。
    /// false时调用方必须停止关闭/退出/切换，草稿保持可编辑。
    @discardableResult
    func finishInlineEditing() -> Bool {
        // 导航、关窗、退出同样要落盘项目备注，否则最后一段输入会丢在节流里。
        flushProjectNotes()
        editingTitleField?.commitEditing()
        guard let editor = inlineEditor else { return true }
        guard let draft = editor.collectForSaving() else { return false }
        var initial = editor.original
        initial.title = initial.title.trimmingCharacters(in: .whitespacesAndNewlines)
        initial.notes = initial.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        var current = draft
        current.notes = current.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if editor.isNew, draft.title.isEmpty,
           draft.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           draft.checklist.isEmpty, current == initial {
            cancelInlineEditing()
            return true
        }
        return saveInlineEditing()
    }

    /// false表示标题无效、保存失败或并发冲突；草稿与当前页面保持不变。
    @discardableResult
    func saveInlineEditing() -> Bool {
        guard let editor = inlineEditor else { return true }
        guard let draft = editor.collectForSaving() else { return false }
        guard !draft.title.isEmpty else {
            editor.showError("请输入任务标题，或按 Escape 取消草稿。"); editor.focusTitle(); return false
        }
        if !editor.isNew, draft == editor.original {
            cancelInlineEditing()
            return true
        }
        if editor.isNew, store.todo(draft.id) != nil {
            editor.showError("此任务标识已存在。请取消草稿后重新新建，避免覆盖任务。")
            return false
        }
        if !editor.isNew {
            guard let latest = store.todo(draft.id), latest == editor.original else {
                editor.showError("任务已被其他操作修改。请取消草稿后重新编辑，避免覆盖更新。")
                return false
            }
        }
        savingInline = true
        let success = store.save(draft)
        savingInline = false
        guard success else {
            editor.showError(store.errorMessage ?? "保存失败，草稿已保留，请重试。")
            return false
        }
        inlineEditor = nil
        reload(); selectTask(draft.id)
        focusList()
        onInlineEditingChanged?(false)
        return true
    }

    func cancelInlineEditing() {
        guard let editor = inlineEditor else { return }
        let id = editor.original.id
        inlineEditor = nil
        reload(); selectTask(id)
        focusList()
        onInlineEditingChanged?(false)
    }
}
