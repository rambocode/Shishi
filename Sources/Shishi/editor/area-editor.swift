import AppKit
import Foundation
import ShishiCore

final class AreaEditorController: EditorFormController {
    private let store: TaskStore
    private var draft: Area
    private let titleField = NSTextField()
    var onFinish: ((UUID?) -> Void)?
    init(store: TaskStore, area: Area) {
        self.store = store; draft = area
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func buildForm() {
        titleField.stringValue = draft.title; titleField.placeholderString = "区域名称"
        titleStyle(titleField)
        row("区域名称", titleField)
    }
    override func saveDraft() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { error("请输入区域名称。"); return }
        draft.title = title
        guard store.saveArea(draft) else { error(store.errorMessage ?? "区域保存失败，请重试。"); return }
        onFinish?(draft.id)
    }
    override func cancelDraft() { onFinish?(nil) }
}
