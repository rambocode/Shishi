import Foundation

public enum ImportedMerge {
    /// 同 ID 的导入内容覆盖可表达字段；本地软删除标记始终保留，未导入记录与分组保留。
    /// 同源持续关闭且未携带 pending 的记录保留本地待归档状态；来源明确重新开放时清除 pending。
    /// added/updated 统计顶层任务、项目、区域；分组包含在所属项目变更中。
    public static func merge(_ incoming: Snapshot, into current: Snapshot) throws -> (snapshot: Snapshot, added: Int, updated: Int) {
        try Domain.validate(incoming)
        try Domain.validate(current)
        var value = current
        if incoming.tags != nil { value.tags = Array(Set((current.tags ?? []) + (incoming.tags ?? []))).sorted() }
        for area in incoming.areas {
            if let index = value.areas.firstIndex(where: { $0.id == area.id }) { value.areas[index] = area }
            else { value.areas.append(area) }
        }
        for var project in incoming.projects {
            if let index = value.projects.firstIndex(where: { $0.id == project.id }) {
                let old = value.projects[index]
                let closed = project.completed || project.status == .completed || project.status == .canceled
                let wasClosed = old.completed || old.status == .completed || old.status == .canceled
                if !closed { project.pendingArchiveDate = nil }
                else if wasClosed && sameSource(project.source, old.source) {
                    project.pendingArchiveDate = project.pendingArchiveDate ?? old.pendingArchiveDate
                }
                project.deletedAt = value.projects[index].deletedAt ?? project.deletedAt
                let importedIDs = Set(project.headings.map(\.id))
                project.headings += value.projects[index].headings.filter { !importedIDs.contains($0.id) }
                value.projects[index] = project
            } else { value.projects.append(project) }
        }
        for var todo in incoming.todos {
            if let index = value.todos.firstIndex(where: { $0.id == todo.id }) {
                let old = value.todos[index]
                if todo.status == .open { todo.pendingArchiveDate = nil }
                else if old.status != .open && sameSource(todo.source, old.source) {
                    todo.pendingArchiveDate = todo.pendingArchiveDate ?? old.pendingArchiveDate
                }
                todo.deletedAt = value.todos[index].deletedAt ?? todo.deletedAt
                value.todos[index] = todo
            } else { value.todos.append(todo) }
        }
        // 项目区域变化也作用于未在此次导入中的本地子任务。
        let projects = Dictionary(uniqueKeysWithValues: value.projects.map { ($0.id, $0) })
        for index in value.todos.indices {
            if let projectID = value.todos[index].projectID, let project = projects[projectID] { value.todos[index].areaID = project.areaID }
        }
        try Domain.validate(value)
        var added = 0, updated = 0
        func count<T: Identifiable & Equatable>(_ before: [T], _ after: [T]) where T.ID == UUID {
            let old = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
            for item in after {
                if let previous = old[item.id] { if previous != item { updated += 1 } }
                else { added += 1 }
            }
        }
        count(current.areas, value.areas); count(current.projects, value.projects); count(current.todos, value.todos)
        return (value, added, updated)
    }

    private static func sameSource(_ first: SourceInfo?, _ second: SourceInfo?) -> Bool {
        guard let first, let second else { return false }
        return first.provider == second.provider && first.identifier == second.identifier
    }
}
