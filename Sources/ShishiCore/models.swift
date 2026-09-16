import Foundation

public enum TaskStatus: String, Codable, CaseIterable { case open, completed, canceled }
public enum Schedule: String, Codable, CaseIterable { case inbox, anytime, someday, dated }
public enum RepeatUnit: String, Codable, CaseIterable { case day, week, month, year }
/// 可选来源信息确保旧 JSON 仍可解码；metadata 保留无法由本地字段完整表达的原规则。
public struct SourceInfo: Codable, Equatable {
    public var provider: String
    public var identifier: String
    public var metadata: [String: String]
    public init(provider: String, identifier: String, metadata: [String: String] = [:]) {
        self.provider = provider; self.identifier = identifier; self.metadata = metadata
    }
}
public struct RepeatRule: Codable, Equatable {
    public var unit: RepeatUnit
    public var interval: Int
    public var afterCompletion: Bool
    public init(unit: RepeatUnit, interval: Int = 1, afterCompletion: Bool = false) {
        self.unit = unit; self.interval = interval; self.afterCompletion = afterCompletion
    }
}
public struct ChecklistItem: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var completed: Bool
    public var source: SourceInfo?
    public init(id: UUID = UUID(), title: String, completed: Bool = false, source: SourceInfo? = nil) {
        self.id = id; self.title = title; self.completed = completed; self.source = source
    }
}
public struct Todo: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var status: TaskStatus
    public var schedule: Schedule
    public var startDate: Date?
    public var deadline: Date?
    /// 本地显式提醒时刻；缺失字段解码为 nil，不从来源 metadata 推导。
    public var reminderDate: Date?
    public var deadlineSuppressionDate: Date?
    public var evening: Bool
    public var projectID: UUID?
    public var areaID: UUID?
    public var headingID: UUID?
    public var tags: [String]
    public var checklist: [ChecklistItem]
    public var repeatRule: RepeatRule?
    public var createdAt: Date
    public var completedAt: Date?
    public var pendingArchiveDate: Date?
    public var deletedAt: Date?
    public var order: Double
    public var source: SourceInfo?
    public init(id: UUID = UUID(), title: String, notes: String = "", status: TaskStatus = .open,
                schedule: Schedule = .inbox, startDate: Date? = nil, deadline: Date? = nil,
                evening: Bool = false, projectID: UUID? = nil, areaID: UUID? = nil,
                headingID: UUID? = nil, tags: [String] = [], checklist: [ChecklistItem] = [],
                repeatRule: RepeatRule? = nil, createdAt: Date = Date(), completedAt: Date? = nil,
                deletedAt: Date? = nil, order: Double = 0, source: SourceInfo? = nil, deadlineSuppressionDate: Date? = nil,
                reminderDate: Date? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.status = status
        self.schedule = schedule; self.startDate = startDate; self.deadline = deadline
        self.deadlineSuppressionDate = deadlineSuppressionDate
        self.reminderDate = reminderDate
        self.evening = evening; self.projectID = projectID; self.areaID = areaID; self.headingID = headingID
        self.tags = tags; self.checklist = checklist; self.repeatRule = repeatRule
        self.createdAt = createdAt; self.completedAt = completedAt; self.deletedAt = deletedAt; self.order = order; self.source = source
    }
}
public struct Area: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var order: Double
    public var source: SourceInfo?
    public var tags: [String]?
    public init(id: UUID = UUID(), title: String, order: Double = 0, source: SourceInfo? = nil, tags: [String]? = nil) { self.id = id; self.title = title; self.order = order; self.source = source; self.tags = tags }
}
public struct Heading: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var order: Double
    public var deletedAt: Date?
    public var status: TaskStatus?
    public var notes: String?
    public var source: SourceInfo?
    public init(id: UUID = UUID(), title: String, order: Double = 0, deletedAt: Date? = nil, status: TaskStatus? = nil, notes: String? = nil, source: SourceInfo? = nil) {
        self.id = id; self.title = title; self.order = order; self.deletedAt = deletedAt; self.status = status; self.notes = notes; self.source = source
    }
}
public struct Project: Codable, Identifiable, Equatable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var areaID: UUID?
    public var deadline: Date?
    public var completed: Bool
    public var headings: [Heading]
    public var order: Double
    public var deletedAt: Date?
    public var status: TaskStatus?
    public var startDate: Date?
    public var schedule: Schedule?
    public var source: SourceInfo?
    public var tags: [String]?
    public var repeatRule: RepeatRule?
    public var evening: Bool?
    public var pendingArchiveDate: Date?
    public init(id: UUID = UUID(), title: String, notes: String = "", areaID: UUID? = nil,
                deadline: Date? = nil, completed: Bool = false, headings: [Heading] = [], order: Double = 0,
                deletedAt: Date? = nil, status: TaskStatus? = nil, startDate: Date? = nil,
                schedule: Schedule? = nil, source: SourceInfo? = nil, tags: [String]? = nil,
                repeatRule: RepeatRule? = nil, evening: Bool? = nil) {
        self.id = id; self.title = title; self.notes = notes; self.areaID = areaID
        self.deadline = deadline; self.completed = completed; self.headings = headings; self.order = order
        self.deletedAt = deletedAt; self.status = status; self.startDate = startDate; self.schedule = schedule; self.source = source; self.tags = tags
        self.repeatRule = repeatRule; self.evening = evening
    }
}
public enum Route: Hashable {
    case inbox, today, upcoming, anytime, someday, logbook, trash
    case area(UUID), project(UUID), search(String), tag(String)
}
public struct Snapshot: Codable, Equatable {
    public var version: Int
    public var todos: [Todo]
    public var projects: [Project]
    public var areas: [Area]
    public var tags: [String]?
    public init(version: Int = 1, todos: [Todo] = [], projects: [Project] = [], areas: [Area] = [], tags: [String]? = nil) {
        self.version = version; self.todos = todos; self.projects = projects; self.areas = areas; self.tags = tags
    }
}
