import Foundation

/// 项目任务的只读快照；检查项和来源重复模板不属于项目任务统计。
public struct ProjectSummary {
    public let openCount: Int
    public let completedCount: Int
    public let canceledCount: Int
    public let totalCount: Int
    /// 已完成或取消的任务，按完成时间（缺失时用创建时间）倒序，同时间保留输入顺序。
    public let recordedItems: [Todo]

    /// 取消任务不进入分母；没有开放或完成任务时返回零。
    public var fraction: Double {
        let denominator = openCount + completedCount
        return denominator == 0 ? 0 : Double(completedCount) / Double(denominator)
    }

    /// 仅统计 ID 属于此项目且任务、项目、所属标题未删除的实体，不访问存储。
    public init(project: Project, tasks: [Todo]) {
        let deletedHeadings = Set(project.headings.filter { $0.deletedAt != nil }.map(\.id))
        let eligible = tasks.filter { task in
            project.deletedAt == nil && task.projectID == project.id && task.deletedAt == nil
                && task.headingID.map { !deletedHeadings.contains($0) } != false
                && task.source?.metadata["repeatTemplate"] != "true"
        }
        openCount = eligible.filter { $0.status == .open }.count
        completedCount = eligible.filter { $0.status == .completed }.count
        canceledCount = eligible.filter { $0.status == .canceled }.count
        totalCount = eligible.count
        recordedItems = eligible.enumerated().filter { $0.element.status != .open }.sorted { lhs, rhs in
            let leftDate = lhs.element.completedAt ?? lhs.element.createdAt
            let rightDate = rhs.element.completedAt ?? rhs.element.createdAt
            return leftDate == rightDate ? lhs.offset < rhs.offset : leftDate > rightDate
        }.map(\.element)
    }
}
