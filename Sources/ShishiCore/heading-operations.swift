import Foundation

/// 项目内标题分组的整组操作（存档、移动、转换为项目、删除）。
/// 与 ProjectOperations 一致：先在候选快照上完成全部修改并验证，失败抛错且不修改调用方数据。
public enum HeadingOperations {
    /// 在项目列表中显示的标题：未删除且未存档。
    public static func isVisible(_ heading: Heading) -> Bool {
        heading.deletedAt == nil && (heading.status == nil || heading.status == .open)
    }

    /// 存档：完成标题下全部开放待办，并把标题标为已完成，从项目列表中隐藏。
    /// 重复待办走 Domain.complete，照常生成后继；后继所属标题已隐藏时由列表归入无标题区。
    public static func archive(_ headingID: UUID, in projectID: UUID, snapshot: inout Snapshot, now: Date = Date()) throws {
        var candidate = snapshot
        let (projectIndex, headingIndex) = try locate(headingID, in: projectID, snapshot: candidate)
        let ids = candidate.todos.filter {
            $0.projectID == projectID && $0.headingID == headingID && $0.status == .open && Domain.deletionDate($0, in: candidate) == nil
        }.map(\.id)
        for id in ids {
            guard Domain.complete(id, in: &candidate, now: now) else { throw DataError.invalid("无法计算下一个重复日期，标题未存档。") }
        }
        candidate.projects[projectIndex].headings[headingIndex].status = .completed
        try Domain.validate(candidate)
        snapshot = candidate
    }

    /// 移动：标题连同其下全部待办移到另一个开放项目的末尾，保留标题 ID。
    public static func move(_ headingID: UUID, from projectID: UUID, to targetID: UUID, snapshot: inout Snapshot) throws {
        guard projectID != targetID else { return }
        var candidate = snapshot
        let (projectIndex, headingIndex) = try locate(headingID, in: projectID, snapshot: candidate)
        guard let targetIndex = candidate.projects.firstIndex(where: { $0.id == targetID }), isOpen(candidate.projects[targetIndex]) else {
            throw DataError.invalid("目标项目不存在或已关闭。")
        }
        var heading = candidate.projects[projectIndex].headings.remove(at: headingIndex)
        heading.order = (candidate.projects[targetIndex].headings.map(\.order).max() ?? -1) + 1
        candidate.projects[targetIndex].headings.append(heading)
        let areaID = candidate.projects[targetIndex].areaID
        for i in candidate.todos.indices where candidate.todos[i].projectID == projectID && candidate.todos[i].headingID == headingID {
            candidate.todos[i].projectID = targetID
            candidate.todos[i].areaID = areaID
        }
        try Domain.validate(candidate)
        snapshot = candidate
    }

    /// 转换为项目：用标题名和备注新建同区域项目，标题下全部待办移入新项目，原标题移除。返回新项目 ID。
    @discardableResult
    public static func convertToProject(_ headingID: UUID, in projectID: UUID, snapshot: inout Snapshot) throws -> UUID {
        var candidate = snapshot
        let (projectIndex, headingIndex) = try locate(headingID, in: projectID, snapshot: candidate)
        let source = candidate.projects[projectIndex]
        let heading = candidate.projects[projectIndex].headings.remove(at: headingIndex)
        let project = Project(title: heading.title, notes: heading.notes ?? "", areaID: source.areaID,
                              order: (candidate.projects.map(\.order).max() ?? -1) + 1)
        candidate.projects.append(project)
        for i in candidate.todos.indices where candidate.todos[i].projectID == projectID && candidate.todos[i].headingID == headingID {
            candidate.todos[i].projectID = project.id
            candidate.todos[i].headingID = nil
            candidate.todos[i].areaID = project.areaID
        }
        try Domain.validate(candidate)
        snapshot = candidate
        return project.id
    }

    /// 删除：给标题打删除标记，其下待办经 Domain.deletionDate 一并进入废纸篓，可撤销或逐条恢复。
    public static func trash(_ headingID: UUID, in projectID: UUID, snapshot: inout Snapshot, now: Date = Date()) throws {
        var candidate = snapshot
        let (projectIndex, headingIndex) = try locate(headingID, in: projectID, snapshot: candidate)
        candidate.projects[projectIndex].headings[headingIndex].deletedAt = now
        try Domain.validate(candidate)
        snapshot = candidate
    }

    /// 只有开放项目里可见的标题才能被操作；返回项目与标题在快照中的下标。
    private static func locate(_ headingID: UUID, in projectID: UUID, snapshot: Snapshot) throws -> (Int, Int) {
        guard let projectIndex = snapshot.projects.firstIndex(where: { $0.id == projectID }), isOpen(snapshot.projects[projectIndex]) else {
            throw DataError.invalid("项目不存在或已关闭。")
        }
        guard let headingIndex = snapshot.projects[projectIndex].headings.firstIndex(where: { $0.id == headingID && isVisible($0) }) else {
            throw DataError.invalid("标题不存在或已删除。")
        }
        return (projectIndex, headingIndex)
    }

    private static func isOpen(_ project: Project) -> Bool {
        project.deletedAt == nil && !project.completed && (project.status == nil || project.status == .open)
    }
}
