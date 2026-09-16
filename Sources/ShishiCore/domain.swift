import Foundation

public enum Domain {
    public static func validate(_ value: Snapshot) throws {
        guard value.version == 1 else { throw DataError.invalid("不支持的数据版本：\(value.version)") }
        func unique(_ ids: [UUID]) throws {
            guard Set(ids).count == ids.count else { throw DataError.invalid("数据包含重复 ID") }
        }
        func title(_ text: String) throws {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DataError.invalid("标题不能为空") }
        }
        func dates(_ values: [Date?]) throws {
            guard values.compactMap({ $0 }).allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else { throw DataError.invalid("日期无效") }
        }
        func tags(_ values: [String]?) throws {
            guard (values ?? []).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw DataError.invalid("标签不能为空") }
        }
        try tags(value.tags)
        var ids = value.todos.map(\.id)
        ids.append(contentsOf: value.projects.map(\.id))
        ids.append(contentsOf: value.areas.map(\.id))
        ids.append(contentsOf: value.projects.flatMap { $0.headings.map(\.id) })
        ids.append(contentsOf: value.todos.flatMap { $0.checklist.map(\.id) })
        try unique(ids)
        let areas = Set(value.areas.map(\.id))
        let projects = Dictionary(uniqueKeysWithValues: value.projects.map { ($0.id, $0) })
        for area in value.areas { try title(area.title); try tags(area.tags); guard area.order.isFinite else { throw DataError.invalid("排序值无效") } }
        for project in value.projects {
            if let rule = project.repeatRule, !(1...10000).contains(rule.interval) { throw DataError.invalid("重复间隔须在 1 到 10000 之间") }
            try title(project.title)
            try tags(project.tags)
            try dates([project.deadline, project.startDate, project.deletedAt, project.pendingArchiveDate])
            if project.schedule == .dated && project.startDate == nil { throw DataError.invalid("项目安排日期不能为空") }
            guard project.order.isFinite, project.areaID.map({ areas.contains($0) }) ?? true else { throw DataError.invalid("项目引用或排序无效") }
            for heading in project.headings { try title(heading.title); try dates([heading.deletedAt]); guard heading.order.isFinite else { throw DataError.invalid("标题分组排序无效") } }
        }
        for todo in value.todos {
            try title(todo.title)
            try dates([todo.startDate, todo.deadline, todo.reminderDate, todo.deadlineSuppressionDate, todo.createdAt, todo.completedAt, todo.deletedAt, todo.pendingArchiveDate])
            guard todo.order.isFinite, todo.areaID.map({ areas.contains($0) }) ?? true,
                  todo.projectID.map({ projects[$0] != nil }) ?? true else { throw DataError.invalid("任务引用或排序无效") }
            // 项目是区域归属的权威；nil 兼容旧数据仅保存项目引用的形式。
            if let projectID = todo.projectID, let areaID = todo.areaID, projects[projectID]?.areaID != areaID {
                throw DataError.invalid("任务区域必须与项目区域一致")
            }
            if let heading = todo.headingID {
                guard let project = todo.projectID, projects[project]?.headings.contains(where: { $0.id == heading }) == true else { throw DataError.invalid("任务标题分组引用无效") }
            }
            if todo.schedule == .dated && todo.startDate == nil { throw DataError.invalid("安排日期不能为空") }
            if let rule = todo.repeatRule, rule.interval < 1 || rule.interval > 10000 { throw DataError.invalid("重复间隔须在 1 到 10000 之间") }
            for item in todo.checklist { try title(item.title) }
        }
    }

    public static func normalized(_ todo: Todo) -> Todo {
        var result = todo
        result.title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        result.tags = result.tags.compactMap {
            let tag = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !tag.isEmpty && seen.insert(tag).inserted ? tag : nil
        }
        // 指定归属即完成收件箱整理，避免编辑器只选项目后任务从常用列表消失。
        if result.schedule == .inbox && (result.projectID != nil || result.areaID != nil) { result.schedule = .anytime }
        if result.schedule != .dated { result.startDate = nil; result.evening = false }
        if result.status == .open { result.completedAt = nil; result.pendingArchiveDate = nil }
        return result
    }

    public static func items(in value: Snapshot, for route: Route, now: Date = Date(), calendar: Calendar = .current) -> [Todo] {
        let day = calendar.startOfDay(for: now)
        let result = value.todos.filter { todo in
            switch route {
            case .trash: return deletionDate(todo, in: value) != nil
            case .logbook: return deletionDate(todo, in: value) == nil && todo.status != .open && todo.pendingArchiveDate == nil
            default: guard deletionDate(todo, in: value) == nil && (todo.status == .open || todo.pendingArchiveDate != nil) else { return false }
            }
            if let projectID = todo.projectID, value.projects.contains(where: { $0.id == projectID && ($0.completed || $0.status == .completed || $0.status == .canceled) && $0.pendingArchiveDate == nil }) { return false }
            if todo.source?.metadata["repeatTemplate"] == "true" {
                switch route { case .upcoming, .search: break; default: return false }
            }
            switch route {
            case .inbox: return todo.schedule == .inbox && todo.projectID == nil && todo.areaID == nil
            case .today:
                let suppression = todo.deadlineSuppressionDate ?? suppressionDate(todo.source)
                return todo.startDate.map { calendar.startOfDay(for: $0) <= day } == true || deadlineDue(todo.deadline, suppression: suppression, day: day, calendar: calendar)
            case .upcoming: return todo.startDate.map { calendar.startOfDay(for: $0) > day } == true || todo.deadline.map { calendar.startOfDay(for: $0) > day } == true
            case .anytime: return todo.schedule == .anytime || (todo.schedule == .dated && todo.startDate.map { calendar.startOfDay(for: $0) <= day } == true)
            case .someday: return todo.schedule == .someday
            case .project(let id): return todo.projectID == id
            case .area(let id):
                if let projectID = todo.projectID { return value.projects.first { $0.id == projectID }?.areaID == id }
                return todo.areaID == id
            case .tag(let tag): return tags(for: todo, in: value).contains(tag)
            case .search(let text):
                let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return query.isEmpty || ([todo.title, todo.notes] + todo.tags + todo.checklist.map(\.title)).contains { $0.localizedCaseInsensitiveContains(query) }
            case .trash, .logbook: return false
            }
        }
        return result.sorted {
            if case .logbook = route { return ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
            if case .trash = route { return (deletionDate($0, in: value) ?? $0.createdAt) > (deletionDate($1, in: value) ?? $1.createdAt) }
            var firstOrder = $0.order, secondOrder = $1.order
            if case .today = route {
                firstOrder = $0.source?.metadata["todayIndex"].flatMap(Double.init) ?? firstOrder
                secondOrder = $1.source?.metadata["todayIndex"].flatMap(Double.init) ?? secondOrder
            }
            if firstOrder != secondOrder { return firstOrder < secondOrder }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
    public static func tags(for todo: Todo, in snapshot: Snapshot) -> [String] {
        let project = snapshot.projects.first { $0.id == todo.projectID }
        let area = snapshot.areas.first { $0.id == (project?.areaID ?? todo.areaID) }
        return Array(Set(todo.tags + (project?.tags ?? []) + (area?.tags ?? []))).sorted()
    }
    private static func suppressionDate(_ source: SourceInfo?) -> Date? {
        guard let raw = source?.metadata["deadlineSuppressionDate"].flatMap(Int64.init) else { return nil }
        return try? ThingsValues.date(raw)
    }
    private static func deadlineDue(_ deadline: Date?, suppression: Date?, day: Date, calendar: Calendar) -> Bool {
        guard let deadline, calendar.startOfDay(for: deadline) <= day else { return false }
        return suppression.map { calendar.startOfDay(for: $0) < calendar.startOfDay(for: deadline) } ?? true
    }

    /// 项目是独立列表项，不能伪装成待办；Today 数量由待办与项目共同组成。
    public static func projects(in snapshot: Snapshot, for route: Route, now: Date = Date(), calendar: Calendar = .current) -> [Project] {
        let day = calendar.startOfDay(for: now)
        return snapshot.projects.filter { project in
            let closed = project.completed || project.status == .completed || project.status == .canceled
            switch route {
            case .trash: return project.deletedAt != nil
            case .logbook: return project.deletedAt == nil && closed && project.pendingArchiveDate == nil
            default: guard project.deletedAt == nil && (!closed || project.pendingArchiveDate != nil) else { return false }
            }
            switch route {
            case .today: return project.startDate.map { calendar.startOfDay(for: $0) <= day } == true || deadlineDue(project.deadline, suppression: suppressionDate(project.source), day: day, calendar: calendar)
            case .upcoming: return project.startDate.map { calendar.startOfDay(for: $0) > day } == true || project.deadline.map { calendar.startOfDay(for: $0) > day } == true
            case .anytime: return project.schedule == nil || project.schedule == .anytime || (project.schedule == .dated && project.startDate.map { calendar.startOfDay(for: $0) <= day } == true)
            case .someday: return project.schedule == .someday
            case .area(let id): return project.areaID == id
            case .project(let id): return project.id == id
            case .search(let query): return project.title.localizedCaseInsensitiveContains(query) || project.notes.localizedCaseInsensitiveContains(query)
            case .tag(let tag): return (project.tags ?? []).contains(tag) || snapshot.areas.first { $0.id == project.areaID }?.tags?.contains(tag) == true
            default: return false
            }
        }.sorted {
            let first = $0.source?.metadata["todayIndex"].flatMap(Double.init) ?? $0.order
            let second = $1.source?.metadata["todayIndex"].flatMap(Double.init) ?? $1.order
            if case .today = route, first != second { return first < second }
            return $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order
        }
    }

    public static func deletionDate(_ todo: Todo, in snapshot: Snapshot) -> Date? {
        let project = snapshot.projects.first { $0.id == todo.projectID }
        return todo.deletedAt ?? project?.deletedAt ?? project?.headings.first { $0.id == todo.headingID }?.deletedAt
    }

    /// 仅开放实例首次完成时生成后继；重复规则移交后继，撤销可完整恢复原实例。
    @discardableResult public static func complete(_ id: UUID, in value: inout Snapshot, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let index = value.todos.firstIndex(where: { $0.id == id }), value.todos[index].status == .open, deletionDate(value.todos[index], in: value) == nil else { return true }
        guard now.timeIntervalSinceReferenceDate.isFinite else { return false }
        let original = value.todos[index]
        guard let rule = original.repeatRule else {
            value.todos[index].status = .completed; value.todos[index].completedAt = now
            return true
        }
        guard (1...10000).contains(rule.interval) else { return false }
        let base = rule.afterCompletion ? now : (original.startDate ?? now)
        guard base.timeIntervalSinceReferenceDate.isFinite,
              let nextDate = nextOccurrence(after: base, rule: rule, metadata: original.source?.metadata, now: now, calendar: calendar) else { return false }
        var next = original
        // 消费原规则保证幂等，随机 ID 避免与相邻 UUID 的独立任务碰撞而丢失周期。
        var used = Set(value.todos.map(\.id) + value.projects.map(\.id) + value.areas.map(\.id))
        used.formUnion(value.projects.flatMap { $0.headings.map(\.id) })
        used.formUnion(value.todos.flatMap { $0.checklist.map(\.id) })
        func freshID() -> UUID {
            var id = UUID()
            while !used.insert(id).inserted { id = UUID() }
            return id
        }
        next.id = freshID()
        next.status = .open; next.completedAt = nil; next.createdAt = now
        next.pendingArchiveDate = nil
        next.deadlineSuppressionDate = nil
        next.source?.metadata.removeValue(forKey: "repeatTemplate")
        next.source?.metadata.removeValue(forKey: "deadlineSuppressionDate")
        next.startDate = nextDate; next.schedule = .dated; next.deletedAt = nil
        if let reminder = original.reminderDate {
            let anchor = original.startDate ?? base
            guard reminder.timeIntervalSinceReferenceDate.isFinite else { return false }
            let offset = calendar.dateComponents([.day, .hour, .minute, .second, .nanosecond], from: anchor, to: nextDate)
            guard let shifted = calendar.date(byAdding: offset, to: reminder), shifted.timeIntervalSinceReferenceDate.isFinite else { return false }
            next.reminderDate = shifted
        }
        next.checklist = original.checklist.map { ChecklistItem(id: freshID(), title: $0.title) }
        if let deadline = original.deadline {
            guard deadline.timeIntervalSinceReferenceDate.isFinite else { return false }
            guard let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: original.startDate ?? base), to: calendar.startOfDay(for: deadline)).day else { return false }
            guard let shifted = calendar.date(byAdding: .day, value: offset, to: nextDate), shifted.timeIntervalSinceReferenceDate.isFinite else { return false }
            next.deadline = shifted
        }
        // 仅在后继完整计算成功后消费规则，失败保留原实例及周期。
        value.todos[index].status = .completed
        value.todos[index].completedAt = now
        value.todos[index].repeatRule = nil
        value.todos.append(next)
        return true
    }

    /// 计算下一个实例的开始日期。完成后重复以完成时刻为锚点推进一个周期即可；
    /// 固定周期以原开始日期为锚点，并跳过所有已经过去的周期：逾期很久的每日重复若只推进一天，
    /// 生成的新实例仍然停在过去的今天列表里，用户会以为“点了完成没有反应”。
    private static func nextOccurrence(after base: Date, rule: RepeatRule, metadata: [String: String]?,
                                       now: Date, calendar: Calendar) -> Date? {
        let component: Calendar.Component
        switch rule.unit { case .day: component = .day; case .week: component = .weekOfYear; case .month: component = .month; case .year: component = .year }
        func occurrence(_ steps: Int) -> Date? {
            guard let raw = calendar.date(byAdding: component, value: rule.interval * steps, to: base),
                  raw.timeIntervalSinceReferenceDate.isFinite else { return nil }
            guard !rule.afterCompletion, let metadata else { return raw }
            return aligned(raw, metadata: metadata, calendar: calendar)
        }
        guard let first = occurrence(1) else { return nil }
        guard !rule.afterCompletion else { return first }
        let today = calendar.startOfDay(for: now)
        let unitDays: Int
        switch rule.unit { case .day: unitDays = 1; case .week: unitDays = 7; case .month: unitDays = 28; case .year: unitDays = 365 }
        var candidate = first
        var steps = 1
        var attempts = 0
        // 先按天数差估算要跳过的周期数，逐个周期循环在跨年重复上会很慢；上限避免异常规则空转。
        while calendar.startOfDay(for: candidate) <= today {
            attempts += 1
            guard attempts <= 200 else { return nil }
            let gap = calendar.dateComponents([.day], from: calendar.startOfDay(for: candidate), to: today).day ?? 0
            steps += max(1, gap / max(1, rule.interval * unitDays))
            guard let next = occurrence(steps) else { return nil }
            candidate = next
        }
        return candidate
    }

    /// Things 导入的月/周/年规则把“第几天、星期几”放在来源信息里，粗算出的日期要按此对齐回规则指定的那天。
    private static func aligned(_ date: Date, metadata: [String: String], calendar: Calendar) -> Date? {
        var result = date
        if let targetDay = metadata["repeatDay"].flatMap(Int.init) {
            var parts = calendar.dateComponents([.year, .month, .hour, .minute, .second], from: result)
            if let month = metadata["repeatMonth"].flatMap(Int.init) { parts.month = month }
            parts.day = 1
            guard let first = calendar.date(from: parts), let range = calendar.range(of: .day, in: .month, for: first) else { return nil }
            parts.day = targetDay == -1 ? range.count : min(max(targetDay, 1), range.count)
            guard let adjusted = calendar.date(from: parts) else { return nil }
            result = adjusted
        }
        if let weekday = metadata["repeatWeekday"].flatMap(Int.init) {
            let delta = (weekday - calendar.component(.weekday, from: result) + 7) % 7
            guard let adjusted = calendar.date(byAdding: .day, value: delta, to: result) else { return nil }
            result = adjusted
        }
        return result
    }
}
