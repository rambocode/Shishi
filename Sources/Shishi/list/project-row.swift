import AppKit
import ShishiCore

final class GeneralProjectRowView: NSView {
    init(_ project: Project, tasks: [Todo], textSize: Int = 14) {
        super.init(frame: .zero)
        let summaryValue = ProjectSummary(project: project, tasks: tasks)
        let icon = ProjectProgressView()
        icon.configure(project: project, summary: summaryValue)
        let title = NSTextField(labelWithString: project.title)
        title.font = .systemFont(ofSize: CGFloat(textSize), weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        let completedCount = summaryValue.completedCount
        let taskCount = summaryValue.openCount + summaryValue.completedCount
        var summary: String
        if project.deletedAt != nil { summary = "已删除 · 项目" }
        else if project.status == .canceled { summary = "已取消 · 项目" }
        else if project.completed || project.status == .completed { summary = "已完成 · 项目" }
        else { summary = taskCount == 0 ? "项目" : "\(completedCount)/\(taskCount)" }
        if let deadline = project.deadline { summary += "  截止 " + deadline.formatted(.dateTime.month().day()) }
        let state = NSTextField(labelWithString: summary)
        state.font = .systemFont(ofSize: 11); state.textColor = .secondaryLabelColor
        for child in [icon, title, state] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10), icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10), title.centerYAnchor.constraint(equalTo: centerYAnchor),
            state.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 10), state.centerYAnchor.constraint(equalTo: centerYAnchor),
            state.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        ])
        toolTip = project.notes
        setAccessibilityElement(true); setAccessibilityLabel(project.title + "，" + summary); setAccessibilityRole(.group)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
}

extension TaskListController {
    func restoreArchivedProject(_ id: UUID) {
        guard var project = store.snapshot.projects.first(where: { $0.id == id }) else { return }
        project.completed = false
        project.deletedAt = nil
        project.status = .open
        // 不改关联任务状态；保存失败由Store的失败通知呈现。
        store.saveProject(project)
    }
}
