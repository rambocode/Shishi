import Foundation
import UserNotifications
import ShishiCore

/// provider 边界只处理系统队列；不修改任务数据，测试可完全替换系统中心。
struct TaskNotificationRequest: Equatable {
    let identifier: String
    let title: String
    let date: Date
}

@MainActor protocol TaskNotificationProvider: AnyObject {
    var unavailabilityReason: String? { get }
    func installDelegate()
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func pendingRequests() async -> [TaskNotificationRequest]
    func removeRequests(_ identifiers: [String])
    func addRequest(_ request: TaskNotificationRequest) async throws
}

extension TaskNotificationProvider {
    var unavailabilityReason: String? { nil }
}

@MainActor final class SystemTaskNotificationProvider: NSObject, TaskNotificationProvider, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter?
    var unavailabilityReason: String? {
        center == nil ? "提醒已保存，但当前未通过应用包运行，无法发送系统通知。请打包并启动拾事.app。" : nil
    }

    init(center: UNUserNotificationCenter? = nil) {
        // swift run / XCTest 没有应用包身份，调用 current() 会抛出 Swift 无法捕获的 ObjC 异常。
        // 必须在获取中心之前检查；正式 .app 包继续使用系统通知。
        if let center { self.center = center }
        else if Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleIdentifier?.isEmpty == false {
            self.center = .current()
        } else { self.center = nil }
    }
    func installDelegate() { center?.delegate = self }
    func authorizationStatus() async -> UNAuthorizationStatus {
        guard let center else { return .notDetermined }
        return await center.notificationSettings().authorizationStatus
    }
    func requestAuthorization() async throws -> Bool {
        guard let center else { throw unavailableError() }
        return try await center.requestAuthorization(options: [.alert, .sound])
    }
    private func unavailableError() -> NSError {
        NSError(domain: "ShishiNotifications", code: 1, userInfo: [NSLocalizedDescriptionKey: unavailabilityReason ?? "系统通知不可用。"])
    }
    func pendingRequests() async -> [TaskNotificationRequest] {
        guard let center else { return [] }
        return await center.pendingNotificationRequests().map {
            TaskNotificationRequest(identifier: $0.identifier, title: $0.content.title,
                                    date: ($0.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() ?? .distantPast)
        }
    }
    func removeRequests(_ identifiers: [String]) { center?.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func addRequest(_ request: TaskNotificationRequest) async throws {
        guard let center else { throw unavailableError() }
        let content = UNMutableNotificationContent()
        content.title = request.title; content.sound = .default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: request.date)
        parts.calendar = calendar; parts.timeZone = calendar.timeZone
        try await center.add(UNNotificationRequest(identifier: request.identifier, content: content,
                                                   trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler(notification.request.identifier.hasPrefix(TaskNotifications.identifierPrefix) ? [.banner, .list, .sound] : [])
    }
}

/// App 强持有一个实例并调用 start。仅用户主动提交新提醒后调用 authorizeAndRefresh。
/// 本地保存与系统调度是两步：返回错误时 reminderDate 仍保留，不能向 UI 报告已调度成功。
@MainActor final class TaskNotifications {
    nonisolated static let identifierPrefix = "shishi.task.reminder."
    static let changed = Notification.Name("ShishiTaskNotificationsChanged")
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var lastError: String?
    private(set) var scheduledIdentifiers: Set<String> = []
    private let store: TaskStore
    private let provider: TaskNotificationProvider
    private let now: () -> Date
    private var observer: NSObjectProtocol?
    private var generation: UInt64 = 0
    private var worker: Task<Void, Never>?
    private var authorizationTask: Task<String?, Never>?

    init(store: TaskStore, provider: TaskNotificationProvider? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store; self.provider = provider ?? SystemTaskNotificationProvider(); self.now = now
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    nonisolated static func identifier(for id: UUID) -> String { identifierPrefix + id.uuidString.lowercased() }

    /// 幂等启动：安装 delegate 和监听并协调队列；不申请权限，不启用旧来源提醒。
    /// 已授权时恢复明确保存的 reminderDate；同时清理关闭、删除或备份恢复遗留请求。
    func start() {
        guard observer == nil else { return }
        provider.installDelegate()
        observer = NotificationCenter.default.addObserver(forName: TaskStore.changed, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    /// 普通编辑、撤销、关闭或删除只刷新系统队列，永远不申请权限。
    func refresh() {
        generation &+= 1
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while true {
                let stamp = generation
                await reconcile(stamp)
                if stamp == generation { break }
            }
            worker = nil
        }
    }

    /// 仅由 App 在 store.save 成功且用户主动新增/修改非 nil 提醒后调用。
    /// nil 表示授权和本轮所有有效提醒协调成功；非 nil 供 UI 展示（包括容量不足）。
    /// 拒绝或系统错误不回滚本地提醒；重复提交合并权限请求。
    func authorizeAndRefresh() async -> String? {
        if let reason = provider.unavailabilityReason {
            lastError = reason; publish(); return reason
        }
        if let authorizationTask { return await authorizationTask.value }
        let task = Task { [self] () -> String? in
            let status = await provider.authorizationStatus()
            var error: String?
            if status == .notDetermined {
                do {
                    if try await !provider.requestAuthorization() { error = "提醒已保存，但通知权限未获允许。请在系统设置中允许拾事通知。" }
                } catch let failure { error = "提醒已保存，但无法申请通知权限：\(failure.localizedDescription)" }
            }
            refresh()
            await waitForRefresh()
            if let error { lastError = error; publish(); return error }
            return lastError
        }
        authorizationTask = task
        let result = await task.value
        authorizationTask = nil
        return result
    }

    /// 可用于协调调用和 fake 测试；不会触发权限申请。
    func waitForRefresh() async { while let worker { await worker.value } }

    private func reconcile(_ stamp: UInt64) async {
        let status = await provider.authorizationStatus()
        guard stamp == generation else { return }
        authorizationStatus = status
        let pending = await provider.pendingRequests()
        guard stamp == generation else { return }
        let owned = pending.filter { $0.identifier.hasPrefix(Self.identifierPrefix) }
        let allowed = status == .authorized || status == .provisional
        let snapshot = store.snapshot
        let time = now()
        let tasks = snapshot.todos.filter { task in
            guard task.status == .open, Domain.deletionDate(task, in: snapshot) == nil,
                  task.source?.metadata["repeatTemplate"] != "true",
                  let date = task.reminderDate, date.timeIntervalSinceReferenceDate.isFinite, date > time else { return false }
            if let project = snapshot.projects.first(where: { $0.id == task.projectID }),
               project.completed || project.status == .completed || project.status == .canceled { return false }
            return true
        }.sorted {
            if $0.reminderDate != $1.reminderDate { return $0.reminderDate! < $1.reminderDate! }
            return $0.id.uuidString < $1.id.uuidString
        }
        let capacity = max(0, 64 - (pending.count - owned.count))
        let desired = allowed ? tasks.prefix(capacity).map {
            // UNCalendarNotificationTrigger 精度为秒，比较队列时使用相同精度。
            TaskNotificationRequest(identifier: Self.identifier(for: $0.id), title: $0.title,
                                    date: Date(timeIntervalSince1970: floor($0.reminderDate!.timeIntervalSince1970)))
        } : []
        let desiredByID = Dictionary(uniqueKeysWithValues: desired.map { ($0.identifier, $0) })
        provider.removeRequests(owned.filter { desiredByID[$0.identifier] != $0 }.map(\.identifier))
        scheduledIdentifiers = Set(owned.filter { desiredByID[$0.identifier] == $0 }.map(\.identifier))
        lastError = allowed ? nil : (tasks.isEmpty ? nil : (provider.unavailabilityReason ?? "提醒已保存，但通知权限未获允许。请在系统设置中允许拾事通知。"))
        if allowed && tasks.count > capacity {
            let localOnly = tasks.dropFirst(capacity).map(\.title).joined(separator: "、")
            lastError = "系统待发通知容量不足，以下 \(tasks.count - capacity) 个任务的提醒仅保存在本地，尚未调度：\(localOnly)。"
        }
        for request in desired where !scheduledIdentifiers.contains(request.identifier) {
            guard stamp == generation else { return }
            guard request.date > now() else { continue }
            do {
                try await provider.addRequest(request)
                // add 无法取消；陈旧添加落地后必须移除，下一轮补回最新同 ID 请求。
                guard stamp == generation else { provider.removeRequests([request.identifier]); return }
                scheduledIdentifiers.insert(request.identifier)
            } catch {
                guard stamp == generation else { provider.removeRequests([request.identifier]); return }
                let failure = "提醒已保存，但系统通知调度失败（\(request.title)）：\(error.localizedDescription)"
                lastError = lastError.map { $0 + "\n" + failure } ?? failure
            }
        }
        publish()
    }
    private func publish() { NotificationCenter.default.post(name: Self.changed, object: self) }
}
