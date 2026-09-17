import Foundation

/// 项目树操作先构造并验证完整候选快照，失败不修改调用方数据。
public enum ProjectOperations {
    /// 所有保存入口共用完成转换。既有实例的规则是完成时的权威，旧编辑副本不能恢复已消费规则。
    /// afterCompletion 以完成时刻计算下个锚点，否则以项目 start/deadline、最早子任务日期依次选取锚点。
    /// 日期使用同一日历位移，保留子任务与项目的相对日数和时间；任何验证或日期失败均抛错且不修改快照。
    @discardableResult public static func save(_ input: Project, in snapshot: inout Snapshot,
                                              now: Date = Date(), calendar: Calendar = .current) throws -> Bool {
        try Domain.validate(snapshot)
        if let rule = input.repeatRule, !(1...10000).contains(rule.interval) { throw DataError.invalid("重复间隔须在 1 到 10000 之间") }
        var candidate = snapshot
        var project = input
        project.title = project.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if project.status != nil { project.status = project.completed ? (project.status == .canceled ? .canceled : .completed) : .open }
        let index = snapshot.projects.firstIndex { $0.id == project.id }
        let old = index.map { snapshot.projects[$0] }
        let completing = old.map { !$0.completed && ($0.status == nil || $0.status == .open) && $0.deletedAt == nil } == true
            && project.completed && project.status != .canceled && project.deletedAt == nil
        // 已完成实例的旧编辑器内容不能把消费掉的规则写回；重新开放后再次完成也使用已存规则。
        if let old, old.repeatRule == nil, (old.completed || old.status == .completed || completing) { project.repeatRule = nil }
        if let index { candidate.projects[index] = project } else { candidate.projects.append(project) }
        let headings = Set(project.headings.map(\.id))
        for i in candidate.todos.indices where candidate.todos[i].projectID == project.id {
            candidate.todos[i].areaID = project.areaID
            if let heading = candidate.todos[i].headingID, !headings.contains(heading) { candidate.todos[i].headingID = nil }
        }
        try Domain.validate(candidate)
        if completing, let rule = old?.repeatRule {
            guard now.timeIntervalSinceReferenceDate.isFinite else { throw DataError.invalid("完成日期无效") }
            var tree = clone(project, in: candidate, repeating: true)
            tree.project.repeatRule = rule
            let dates = tree.tasks.flatMap { [$0.startDate, $0.deadline].compactMap { $0 } }
            let anchor = project.startDate ?? project.deadline ?? dates.min() ?? now
            let component: Calendar.Component
            switch rule.unit { case .day: component = .day; case .week: component = .weekOfYear; case .month: component = .month; case .year: component = .year }
            guard let next = calendar.date(byAdding: component, value: rule.interval, to: rule.afterCompletion ? now : anchor),
                  next.timeIntervalSinceReferenceDate.isFinite else { throw DataError.invalid("无法计算下一个重复日期") }
            let offset = calendar.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: anchor, to: next)
            func shifted(_ date: Date?) throws -> Date? {
                guard let date else { return nil }
                guard let result = calendar.date(byAdding: offset, to: date), result.timeIntervalSinceReferenceDate.isFinite else {
                    throw DataError.invalid("无法平移重复项目日期")
                }
                return result
            }
            // 后继总有明确的周期开始日期，避免无开始日期的原项目使未来实例立即进入随时。
            tree.project.startDate = try shifted(project.startDate) ?? next
            tree.project.schedule = .dated
            tree.project.deadline = try shifted(project.deadline)
            for i in tree.tasks.indices {
                tree.tasks[i].startDate = try shifted(tree.tasks[i].startDate)
                tree.tasks[i].deadline = try shifted(tree.tasks[i].deadline)
                tree.tasks[i].reminderDate = try shifted(tree.tasks[i].reminderDate)
                // 仅重复后继的无日期任务跟随周期开始，显式日期和 someday 安排不覆盖。
                if tree.tasks[i].startDate == nil && tree.tasks[i].deadline == nil && tree.tasks[i].schedule != .someday {
                    tree.tasks[i].startDate = tree.project.startDate
                    tree.tasks[i].schedule = .dated
                }
                tree.tasks[i].createdAt = now
            }
            if let index { candidate.projects[index].repeatRule = nil }
            candidate.projects.append(tree.project); candidate.todos.append(contentsOf: tree.tasks)
        }
        try Domain.validate(candidate)
        snapshot = candidate
        return true
    }

    /// 原子关闭项目及真实的开放子任务；保留既有历史、删除项和内部重复模板。
    /// 仅允许 completed/canceled；失败抛错并保持输入快照不变，重复调用不生成重复后继。
    @discardableResult public static func finish(_ id: UUID, status: TaskStatus, in snapshot: inout Snapshot,
                                                now: Date = Date(), calendar: Calendar = .current) throws -> Bool {
        guard status != .open else { throw DataError.invalid("关闭项目必须选择完成或取消") }
        guard var project = snapshot.projects.first(where: { $0.id == id && $0.deletedAt == nil }) else { return false }
        guard !project.completed && (project.status == nil || project.status == .open) else { return false }
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw DataError.invalid("完成日期无效") }
        var candidate = snapshot
        for index in candidate.todos.indices {
            let task = candidate.todos[index]
            if task.projectID == id && task.status == .open && Domain.deletionDate(task, in: snapshot) == nil
                && task.source?.metadata["repeatTemplate"] != "true" {
                candidate.todos[index].status = status
                candidate.todos[index].completedAt = now
            }
        }
        project.completed = true
        project.status = status
        try save(project, in: &candidate, now: now, calendar: calendar)
        snapshot = candidate
        return true
    }

    /// 手动副本保留任务历史及安排，仅复制未删除的真实子项；内部重复模板不复制，所有来源和重复关联清空。
    @discardableResult public static func duplicate(_ id: UUID, in snapshot: inout Snapshot) throws -> UUID? {
        try Domain.validate(snapshot)
        guard let project = snapshot.projects.first(where: { $0.id == id && $0.deletedAt == nil }) else { return nil }
        let tree = clone(project, in: snapshot, repeating: false)
        var candidate = snapshot
        candidate.projects.append(tree.project)
        candidate.todos.append(contentsOf: tree.tasks)
        try Domain.validate(candidate)
        snapshot = candidate
        return tree.project.id
    }

    private static func clone(_ original: Project, in snapshot: Snapshot, repeating: Bool) -> (project: Project, tasks: [Todo]) {
        var project = original
        project.id = UUID(); project.completed = false; project.status = .open; project.deletedAt = nil; project.source = nil
        if !repeating { project.title += "副本"; project.repeatRule = nil }
        var headings: [UUID: UUID] = [:]
        project.headings = original.headings.filter { $0.deletedAt == nil }.map {
            var heading = $0
            heading.id = UUID(); heading.source = nil
            if repeating { heading.status = .open }
            headings[$0.id] = heading.id
            return heading
        }
        // 必须在清除来源之前过滤内部模板，否则模板会被发布为普通待办并污染周期锚点。
        let tasks = snapshot.todos.filter {
            $0.projectID == original.id && Domain.deletionDate($0, in: snapshot) == nil
                && $0.source?.metadata["repeatTemplate"] != "true"
        }.map {
            var task = $0
            task.id = UUID(); task.projectID = project.id; task.headingID = $0.headingID.flatMap { headings[$0] }
            task.source = nil; task.repeatRule = nil
            if !repeating { task.reminderDate = nil }
            task.checklist = $0.checklist.map {
                var item = $0; item.id = UUID(); item.source = nil
                if repeating { item.completed = false }
                return item
            }
            if repeating { task.status = .open; task.completedAt = nil; task.deletedAt = nil; task.deadlineSuppressionDate = nil }
            return task
        }
        return (project, tasks)
    }
}
