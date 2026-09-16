import Foundation
import ShishiCore

enum IntegrationAccess: Equatable {
    case notDetermined, denied, restricted, writeOnly, authorized
    var message: String {
        switch self {
        case .notDetermined: return "尚未授权；点击授权后才会请求访问。"
        case .denied: return "访问已拒绝或撤销；可自行前往系统设置更改权限。"
        case .restricted: return "系统限制访问。"
        case .writeOnly: return "仅有写入权限，无法读取日历；请授予完整访问。"
        case .authorized: return "已获得读取权限。"
        }
    }
}
enum IntegrationKind: Hashable, Sendable { case calendar, reminders }
struct IntegrationList: Equatable, Sendable { let id: String; let title: String }
struct AgendaEvent: Equatable, Sendable {
    let id: String
    let title: String
    let calendarTitle: String
    let start: Date
    let end: Date
    let allDay: Bool
}
struct ReminderRecord: Equatable, Sendable {
    let id: String
    let title: String
    let notes: String
    let due: Date?
}
/// Providers never request access from a read method. Implementations must recheck permission at I/O time.
protocol SystemIntegrationProvider: AnyObject {
    func access(_ kind: IntegrationKind) -> IntegrationAccess
    func request(_ kind: IntegrationKind) async throws
    func lists(_ kind: IntegrationKind) async throws -> [IntegrationList]
    func events(start: Date, end: Date, ids: Set<String>) async throws -> [AgendaEvent]
    func reminders(ids: Set<String>) async throws -> [ReminderRecord]
}

enum IntegrationError: LocalizedError {
    case unavailable, fetchFailed
    var errorDescription: String? { self == .unavailable ? "权限已失效，未读取数据。" : "无法读取系统数据，请重试。" }
}
