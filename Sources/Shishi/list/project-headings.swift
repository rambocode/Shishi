import AppKit
import ShishiCore

extension TaskStore {
    /// 追加独立 ID 的标题；空白、无效项目或持久化失败返回 nil，并设置 errorMessage。
    @discardableResult
    func addHeading(title: String, to projectID: UUID) -> UUID? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { errorMessage = "标题不能为空。"; return nil }
        guard var project = snapshot.projects.first(where: { $0.id == projectID }), project.deletedAt == nil else {
            errorMessage = "项目不存在或已删除。"; return nil
        }
        let heading = Heading(title: title, order: (project.headings.map(\.order).max() ?? -1) + 1)
        project.headings.append(heading)
        return saveProject(project) ? heading.id : nil
    }

    /// 只修改指定项目中标题的文字；保留 ID、排序、来源及其他字段，失败不发布状态。
    @discardableResult
    func renameHeading(_ headingID: UUID, title: String, in projectID: UUID) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { errorMessage = "标题不能为空。"; return false }
        guard var project = snapshot.projects.first(where: { $0.id == projectID }), project.deletedAt == nil else {
            errorMessage = "项目不存在或已删除。"; return false
        }
        guard let index = project.headings.firstIndex(where: { $0.id == headingID && $0.deletedAt == nil }) else {
            errorMessage = "标题不存在或已删除。"; return false
        }
        project.headings[index].title = title
        return saveProject(project)
    }
}

/// 供 NSPopover 使用；成功返回标题 ID，取消返回 nil，失败保留草稿且不回调。
@MainActor
final class ProjectHeadingController: NSViewController, NSTextFieldDelegate {
    var onFinish: ((UUID?) -> Void)?
    private let store: TaskStore
    private let projectID: UUID
    private let headingID: UUID?
    private let input = NSTextField()
    private let feedback = NSTextField(wrappingLabelWithString: "")
    private var finished = false

    init(store: TaskStore, projectID: UUID, headingID: UUID? = nil) {
        self.store = store
        self.projectID = projectID
        self.headingID = headingID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let container = NSView()
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        input.placeholderString = "新建标题"
        input.font = .systemFont(ofSize: 13)
        input.setAccessibilityLabel("标题文字")
        input.delegate = self
        if let headingID {
            input.stringValue = store.snapshot.projects.first { $0.id == projectID }?
                .headings.first { $0.id == headingID }?.title ?? ""
        }
        feedback.font = .systemFont(ofSize: 11)
        feedback.textColor = .secondaryLabelColor
        feedback.isHidden = true
        let actions = NSStackView()
        actions.spacing = 8
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelEditing))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "保存", target: self, action: #selector(submit))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        actions.addArrangedSubview(cancel)
        actions.addArrangedSubview(save)
        for child in [input, feedback, actions] { stack.addArrangedSubview(child) }
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            container.widthAnchor.constraint(equalToConstant: 280),
            input.widthAnchor.constraint(equalTo: stack.widthAnchor),
            feedback.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
        view = container
        preferredContentSize = view.fittingSize
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(input)
        input.selectText(nil)
    }

    @objc private func submit() {
        guard !finished else { return }
        let result: UUID?
        if let headingID {
            result = store.renameHeading(headingID, title: input.stringValue, in: projectID) ? headingID : nil
        } else {
            result = store.addHeading(title: input.stringValue, to: projectID)
        }
        guard let result else {
            feedback.stringValue = store.errorMessage ?? "无法保存标题。"
            feedback.isHidden = false
            preferredContentSize = view.fittingSize
            return
        }
        finish(result)
    }

    @objc private func cancelEditing() { finish(nil) }

    private func finish(_ id: UUID?) {
        guard !finished else { return }
        finished = true
        onFinish?(id)
        dismiss(nil)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === input else { return false }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { submit(); return true }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { cancelEditing(); return true }
        return false
    }
}
