import AppKit

/// 历史记录开关属于列表内容，不固定在底部工具栏，不因窗口尺寸改变而遮住任务。
final class ProjectHistoryRowView: NSView {
    private let action: () -> Void
    init(count: Int, expanded: Bool, textSize: Int = 14, action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
        let button = NSButton(title: expanded ? "隐藏 \(count) 个录入项" : "显示 \(count) 个录入项", target: self, action: #selector(toggle))
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: CGFloat(textSize), weight: .medium)
        button.contentTintColor = .secondaryLabelColor
        button.setAccessibilityIdentifier("project-history-toggle")
        button.setAccessibilityLabel(button.title)
        addSubview(button); button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            button.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            button.heightAnchor.constraint(equalToConstant: max(24, CGFloat(textSize) + 8))
        ])
    }
    required init?(coder: NSCoder) { nil }
    @objc private func toggle() { action() }
}
