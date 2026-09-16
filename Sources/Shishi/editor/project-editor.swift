import AppKit
import Foundation
import ShishiCore

final class ProjectEditorController: EditorFormController {
    private let store: TaskStore
    private var draft: Project
    var onFinish: ((UUID?) -> Void)?
    private let titleField = NSTextField()
    private let notes = NotesField(frame: .zero)
    private let area = NSPopUpButton()
    private let deadline: OptionalDateField
    private let completed = NSButton(checkboxWithTitle: "项目已完成", target: nil, action: nil)
    private let headings = NSStackView()
    private var headingRows: [(Heading, NSTextField)] = []
    init(store: TaskStore, project: Project) {
        self.store = store; draft = project; deadline = OptionalDateField(project.deadline)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func buildForm() {
        titleField.stringValue = draft.title; titleField.placeholderString = "项目名称"
        titleStyle(titleField)
        notes.stringValue = draft.notes
        area.addItems(withTitles: ["无区域"] + store.areas.map(\.title))
        area.selectItem(at: store.areas.firstIndex(where: { $0.id == draft.areaID }).map { $0 + 1 } ?? 0)
        completed.state = draft.completed ? .on : .off
        row("项目名称", titleField); row("项目说明", notes); row("区域", area)
        row("截止日期（取消勾选可清除）", deadline); form.addArrangedSubview(completed)
        headings.orientation = .vertical; headings.alignment = .leading; headings.spacing = 8
        row("项目内标题分组", headings)
        for heading in draft.headings { addHeading(heading) }
        form.addArrangedSubview(button("添加标题分组", action: { [weak self] in self?.addHeading(Heading(title: "")) }))
    }
    private func addHeading(_ heading: Heading) {
        let field = NSTextField(string: heading.title)
        field.placeholderString = "标题分组名称"; field.setAccessibilityLabel("标题分组名称")
        let line = NSStackView(views: [field]); line.spacing = 8
        line.addArrangedSubview(button("移除", action: { [weak self, weak line] in
            guard let self, let line else { return }
            self.headingRows.removeAll { $0.0.id == heading.id }
            self.headings.removeArrangedSubview(line); line.removeFromSuperview()
        }))
        headings.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: headings.widthAnchor).isActive = true
        headingRows.append((heading, field))
    }
    override func saveDraft() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { error("请输入项目名称。"); return }
        var values: [Heading] = []
        for (index, row) in headingRows.enumerated() {
            var heading = row.0
            heading.title = row.1.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heading.title.isEmpty else { error("标题分组名称不能为空，请填写或移除空白项。"); return }
            heading.order = Double(index); values.append(heading)
        }
        draft.title = title; draft.notes = notes.stringValue; draft.deadline = deadline.date
        draft.completed = completed.state == .on; draft.headings = values
        let index = area.indexOfSelectedItem - 1
        draft.areaID = store.areas.indices.contains(index) ? store.areas[index].id : nil
        guard store.saveProject(draft) else { error(store.errorMessage ?? "项目保存失败，请重试。"); return }
        onFinish?(draft.id)
    }
    override func cancelDraft() { onFinish?(nil) }
}
