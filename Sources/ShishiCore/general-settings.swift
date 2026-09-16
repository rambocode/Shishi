import Foundation

public enum ArchiveTiming: String, CaseIterable {
    case immediately, daily, manually
    public var title: String {
        switch self { case .immediately: return "立即"; case .daily: return "每天"; case .manually: return "手动" }
    }
}
public enum DockCountMode: String, CaseIterable {
    case none, due, today, inbox
    public var title: String {
        switch self {
        case .none: return "无"
        case .due: return "到期项"
        case .today: return "到期 + 今天"
        case .inbox: return "到期 + 今天 + 收件箱"
        }
    }
}

/// nil 表示已归档（包括旧库历史），日期表示仍留在原列表的完成实例。
public enum CompletionArchive {
    public static func apply(to value: inout Snapshot, timing: ArchiveTiming, now: Date,
                             calendar: Calendar = .current, force: Bool = false) {
        func shouldArchive(_ date: Date?) -> Bool {
            guard let date else { return false }
            return force || timing == .immediately || (timing == .daily && calendar.startOfDay(for: date) < calendar.startOfDay(for: now))
        }
        for i in value.projects.indices {
            let p = value.projects[i]
            if !(p.completed || p.status == .completed || p.status == .canceled) || shouldArchive(p.pendingArchiveDate) {
                value.projects[i].pendingArchiveDate = nil
            }
        }
        // closed 父项目归档后原列表隐藏子项，故其 closed 子项必须同步进入历史。
        // 也修复备份/合并带入的“已归档父项目 + pending 子任务”；不更改开放子项状态。
        let archivedProjects = Set(value.projects.filter {
            ($0.completed || $0.status == .completed || $0.status == .canceled) && $0.pendingArchiveDate == nil
        }.map(\.id))
        for i in value.todos.indices {
            let todo = value.todos[i]
            let archivedParent = todo.status != .open && (todo.projectID.map { archivedProjects.contains($0) } ?? false)
            if todo.status == .open || shouldArchive(todo.pendingArchiveDate) || archivedParent {
                value.todos[i].pendingArchiveDate = nil
            }
        }
    }
}

public enum DockCounts {
    /// 累积范围：到期；到期∪今天；到期∪今天∪收件箱。按对象 ID 去重。
    public static func count(in snapshot: Snapshot, mode: DockCountMode, now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard mode != .none else { return 0 }
        let day = calendar.startOfDay(for: now)
        let closedProjects = Set(snapshot.projects.filter { $0.completed || $0.status == .completed || $0.status == .canceled || $0.deletedAt != nil }.map(\.id))
        let tasks = Domain.items(in: snapshot, for: .search(""), now: now, calendar: calendar).filter {
            $0.status == .open && $0.source?.metadata["repeatTemplate"] != "true" && !($0.projectID.map { closedProjects.contains($0) } ?? false)
        }
        let projects = snapshot.projects.filter { $0.deletedAt == nil && !$0.completed && ($0.status == nil || $0.status == .open) && $0.source?.metadata["repeatTemplate"] != "true" }
        var ids = Set(tasks.filter { $0.deadline.map { calendar.startOfDay(for: $0) <= day } == true }.map(\.id))
        ids.formUnion(projects.filter { $0.deadline.map { calendar.startOfDay(for: $0) <= day } == true }.map(\.id))
        if mode == .today || mode == .inbox {
            let visible = Set(tasks.map(\.id))
            ids.formUnion(Domain.items(in: snapshot, for: .today, now: now, calendar: calendar).filter { visible.contains($0.id) }.map(\.id))
            ids.formUnion(Domain.projects(in: snapshot, for: .today, now: now, calendar: calendar).filter { !$0.completed && ($0.status == nil || $0.status == .open) }.map(\.id))
        }
        if mode == .inbox { ids.formUnion(Domain.items(in: snapshot, for: .inbox, now: now, calendar: calendar).filter { $0.status == .open }.map(\.id)) }
        return ids.count
    }
}
