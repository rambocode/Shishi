import AppKit
import Foundation
import ShishiCore

final class TaskEditorController: EditorFormController {
    private let store: TaskStore
    private var draft: Todo
    private let isNew: Bool
    var onFinish: ((UUID?) -> Void)?
    private let titleField = NSTextField()
    private let notes = NotesField(frame: .zero)
    private let tags = NSTextField()
    private let project = NSPopUpButton()
    private let area = NSPopUpButton()
    private let heading = NSPopUpButton()
    private let schedule = NSPopUpButton()
    // 名称和领域值保持在同一表，避免菜单文字与保存映射分别维护。
    private let schedules: [(String, Schedule)] = [("收件箱", .inbox), ("随时", .anytime), ("某天", .someday), ("指定日期", .dated)]
    private let frequency = NSPopUpButton()
    private let interval = NSTextField()
    private let afterCompletion = NSButton(checkboxWithTitle: "从完成日起计算间隔", target: nil, action: nil)
    private let evening = NSButton(checkboxWithTitle: "今晚", target: nil, action: nil)
    private let checklist = NSStackView()
    private var checklistRows: [(ChecklistItem, NSButton, NSTextField)] = []
    private let start: OptionalDateField
    private let deadline: OptionalDateField
    init(store: TaskStore, todo: Todo, isNew: Bool) {
        self.store = store; draft = todo; self.isNew = isNew
        start = OptionalDateField(todo.startDate); deadline = OptionalDateField(todo.deadline)
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func buildForm() {
        titleField.stringValue = draft.title; titleField.placeholderString = "任务标题"
        titleStyle(titleField)
        notes.stringValue = draft.notes
        tags.stringValue = draft.tags.joined(separator: ", ")
        row(isNew ? "新任务" : "任务标题", titleField); row("备注", notes)
        checklist.orientation = .vertical; checklist.alignment = .leading; checklist.spacing = 6
        row("清单", checklist)
        for item in draft.checklist { addChecklist(item) }
        form.addArrangedSubview(button("添加清单项", action: { [weak self] in self?.addChecklist(ChecklistItem(title: "")) }))
        row("标签（逗号分隔）", tags)
        project.addItems(withTitles: ["无项目"] + store.projects.map(\.title))
        project.selectItem(at: store.projects.firstIndex(where: { $0.id == draft.projectID }).map { $0 + 1 } ?? 0)
        area.addItems(withTitles: ["无区域"] + store.areas.map(\.title))
        area.selectItem(at: store.areas.firstIndex(where: { $0.id == draft.areaID }).map { $0 + 1 } ?? 0)
        project.target = self; project.action = #selector(projectChanged)
        pair("项目", project, "区域", area); row("标题分组", heading)
        refreshHeadings(selected: draft.headingID)
        schedule.addItems(withTitles: schedules.map { $0.0 })
        schedule.selectItem(at: schedules.firstIndex(where: { $0.1 == draft.schedule }) ?? 0)
        schedule.target = self; schedule.action = #selector(scheduleChanged)
        row("安排", schedule)
        let shortcuts = NSStackView()
        for (label, offset, tonight) in [("今天", 0, false), ("今晚", 0, true), ("明天", 1, false)] {
            shortcuts.addArrangedSubview(button(label, action: { [weak self] in
                guard let self else { return }; self.schedule.selectItem(at: 3)
                self.start.set(Calendar.current.date(byAdding: .day, value: offset, to: Calendar.current.startOfDay(for: Date())))
                self.evening.state = tonight ? .on : .off
                self.evening.isEnabled = true
            }))
        }
        for (label, index) in [("随时", 1), ("某天", 2)] {
            shortcuts.addArrangedSubview(button(label, action: { [weak self] in self?.schedule.selectItem(at: index); self?.scheduleChanged() }))
        }
        form.addArrangedSubview(shortcuts)
        pair("开始日期（取消勾选可清除）", start, "截止日期（独立于安排）", deadline)
        start.onChange = { [weak self] in
            guard let self else { return }
            if self.start.date != nil { self.schedule.selectItem(at: 3) }
            self.evening.isEnabled = self.start.date != nil
            if self.start.date == nil { self.evening.state = .off }
        }
        evening.state = draft.evening ? .on : .off; form.addArrangedSubview(evening)
        scheduleChanged()
        frequency.addItems(withTitles: ["不重复", "天", "周", "月", "年"])
        frequency.selectItem(at: draft.repeatRule.flatMap { RepeatUnit.allCases.firstIndex(of: $0.unit) }.map { $0 + 1 } ?? 0)
        interval.stringValue = String(draft.repeatRule?.interval ?? 1)
        afterCompletion.state = draft.repeatRule?.afterCompletion == true ? .on : .off
        pair("重复单位", frequency, "重复间隔（正整数）", interval); form.addArrangedSubview(afterCompletion)
    }
    @objc private func scheduleChanged() {
        let dated = schedules[schedule.indexOfSelectedItem].1 == .dated
        if !dated { start.set(nil); evening.state = .off }
        evening.isEnabled = dated && start.date != nil
    }
    private var selectedProject: Project? { let index = project.indexOfSelectedItem - 1; return store.projects.indices.contains(index) ? store.projects[index] : nil }
    @objc private func projectChanged() { refreshHeadings(selected: nil) }
    private func refreshHeadings(selected: UUID?) {
        heading.removeAllItems(); heading.addItems(withTitles: ["无标题分组"] + (selectedProject?.headings.map(\.title) ?? []))
        heading.selectItem(at: selectedProject?.headings.firstIndex(where: { $0.id == selected }).map { $0 + 1 } ?? 0)
        heading.isEnabled = selectedProject != nil
        area.isEnabled = selectedProject == nil
        if let selectedProject { area.selectItem(at: store.areas.firstIndex(where: { $0.id == selectedProject.areaID }).map { $0 + 1 } ?? 0) }
    }
    private func addChecklist(_ item: ChecklistItem) {
        let check = NSButton(checkboxWithTitle: "", target: nil, action: nil); check.state = item.completed ? .on : .off
        check.setAccessibilityLabel("清单项完成状态")
        let field = NSTextField(string: item.title); field.placeholderString = "清单内容"; field.setAccessibilityLabel("清单内容")
        let line = NSStackView(views: [check, field]); line.spacing = 8
        line.addArrangedSubview(button("移除", action: { [weak self, weak line] in
            guard let self, let line else { return }
            self.checklistRows.removeAll { $0.0.id == item.id }; self.checklist.removeArrangedSubview(line); line.removeFromSuperview()
        }))
        checklist.addArrangedSubview(line)
        line.widthAnchor.constraint(equalTo: checklist.widthAnchor).isActive = true
        checklistRows.append((item, check, field))
    }
    override func saveDraft() {
        let title = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { error("请输入任务标题。"); return }
        guard schedules.indices.contains(schedule.indexOfSelectedItem) else { error("请选择有效的安排方式。"); return }
        let selectedSchedule = schedules[schedule.indexOfSelectedItem].1
        guard selectedSchedule != .dated || start.date != nil else {
            error("指定日期需要设置开始日期，请勾选日期或点击日历选择。"); return
        }
        var rule: RepeatRule?
        if frequency.indexOfSelectedItem > 0 {
            guard let count = Int(interval.stringValue), count > 0 else { error("重复间隔必须是正整数。"); return }
            rule = RepeatRule(unit: RepeatUnit.allCases[frequency.indexOfSelectedItem - 1], interval: count, afterCompletion: afterCompletion.state == .on)
        }
        var items: [ChecklistItem] = []
        for (var item, check, field) in checklistRows {
            item.title = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !item.title.isEmpty else { error("清单内容不能为空，请填写或移除空白项。"); return }
            item.completed = check.state == .on; items.append(item)
        }
        draft.title = title; draft.notes = notes.stringValue; draft.checklist = items
        var seen = Set<String>()
        draft.tags = tags.stringValue.replacingOccurrences(of: "，", with: ",").components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty && seen.insert($0).inserted }
        draft.projectID = selectedProject?.id
        let areaIndex = area.indexOfSelectedItem - 1
        draft.areaID = selectedProject?.areaID ?? (selectedProject == nil && store.areas.indices.contains(areaIndex) ? store.areas[areaIndex].id : nil)
        let headingIndex = heading.indexOfSelectedItem - 1
        draft.headingID = selectedProject.flatMap { $0.headings.indices.contains(headingIndex) ? $0.headings[headingIndex].id : nil }
        draft.schedule = selectedSchedule
        draft.startDate = draft.schedule == .dated ? start.date : nil
        draft.evening = draft.schedule == .dated && evening.state == .on
        draft.deadline = deadline.date; draft.repeatRule = rule
        guard store.save(draft) else { error(store.errorMessage ?? "保存失败，请重试。"); return }
        onFinish?(draft.id)
    }
    override func cancelDraft() { onFinish?(nil) }
}
