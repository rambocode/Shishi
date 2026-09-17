import AppKit
import ShishiCore

/// 仅收集用户选择，不写入数据；nil 表示取消，Escape 与关闭弹窗也不提交。
final class ProjectCompletionController: NSViewController {
    var onChoice: ((TaskStatus?) -> Void)?
    let openCount: Int

    init(openCount: Int) {
        self.openCount = openCount
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override func loadView() {
        view = ProjectCompletionBackground()
        preferredContentSize = NSSize(width: 280, height: 190)
        let message = NSTextField(wrappingLabelWithString: "此项目中仍有 \(openCount) 个未完成的待办事项。\n您想要如何操作？")
        message.font = .systemFont(ofSize: 13)
        let complete = choiceButton("标记为已完成", action: #selector(confirmCompletion), primary: true)
        let cancelTasks = choiceButton("标记为已取消", action: #selector(cancelTasks))
        let dismiss = choiceButton("取消", action: #selector(dismissChoice))
        complete.keyEquivalent = "\r"
        dismiss.keyEquivalent = "\u{1b}"
        let stack = NSStackView(views: [complete, cancelTasks, dismiss])
        stack.orientation = .vertical
        stack.alignment = .leading
        for button in [complete, cancelTasks, dismiss] {
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.spacing = 6
        for child in [message, stack] { view.addSubview(child); child.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            message.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            message.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            message.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
    }

    private func choiceButton(_ title: String, action: Selector, primary: Bool = false) -> NSButton {
        let button = ProjectCompletionButton(title: title, target: self, action: action)
        button.primary = primary
        button.isBordered = false
        button.font = .systemFont(ofSize: 14, weight: primary ? .semibold : .regular)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return button
    }
    @objc private func confirmCompletion() { onChoice?(.completed) }
    @objc private func cancelTasks() { onChoice?(.canceled) }
    @objc private func dismissChoice() { onChoice?(nil) }
}

private final class ProjectCompletionButton: NSButton {
    var primary = false
    override func draw(_ dirtyRect: NSRect) {
        let color = primary ? Appearance.blue : NSColor.quaternaryLabelColor
        (isHighlighted ? color.withAlphaComponent(0.7) : color).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        let text = NSAttributedString(string: title, attributes: [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: primary ? NSColor.white : NSColor.labelColor
        ])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class ProjectCompletionBackground: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
