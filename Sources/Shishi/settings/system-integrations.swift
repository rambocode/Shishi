import AppKit
import EventKit
import ShishiCore

@MainActor final class SystemIntegrations {
    static let shared = SystemIntegrations()
    static let changed = Notification.Name("ShishiSystemIntegrationsChanged")
    private let defaults: UserDefaults
    private let provider: SystemIntegrationProvider
    private var observers: [NSObjectProtocol] = []
    private var revision = 0
    private var refreshTask: Task<Void, Never>?
    private var pendingRequests: Set<IntegrationKind> = []
    init(defaults: UserDefaults = .standard, provider: SystemIntegrationProvider = EventKitIntegrationProvider()) {
        self.defaults = defaults; self.provider = provider
        for name in [Notification.Name.EKEventStoreChanged, NSApplication.didBecomeActiveNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleRefresh() }
            })
        }
    }
    deinit { refreshTask?.cancel(); observers.forEach(NotificationCenter.default.removeObserver) }
    var calendarEnabled: Bool {
        get { defaults.bool(forKey: "system.calendar.enabled") }
        set { defaults.set(newValue && access(.calendar) == .authorized, forKey: "system.calendar.enabled"); notify() }
    }
    var calendarIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "system.calendar.ids") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "system.calendar.ids"); notify() }
    }
    var reminderIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: "system.reminders.ids") ?? []) }
        set { defaults.set(newValue.sorted(), forKey: "system.reminders.ids"); notify() }
    }
    func access(_ kind: IntegrationKind) -> IntegrationAccess { provider.access(kind) }
    private func notify() { revision += 1; NotificationCenter.default.post(name: Self.changed, object: self) }
    private func scheduleRefresh() {
        // Invalidate in-flight results immediately, but coalesce bursts of EventKit changes.
        revision += 1; refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
            guard let self, !Task.isCancelled else { return }
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }
    /// Only call from an explicit authorization action. Reading settings never calls this method.
    func isRequestingAccess(_ kind: IntegrationKind) -> Bool { pendingRequests.contains(kind) }
    func requestAccess(_ kind: IntegrationKind) async throws {
        guard pendingRequests.insert(kind).inserted else { return }
        notify()
        defer { pendingRequests.remove(kind); notify() }
        try await provider.request(kind)
    }
    func lists(_ kind: IntegrationKind) async throws -> [IntegrationList] {
        guard access(kind) == .authorized else { return [] }
        let value = try await provider.lists(kind)
        try Task.checkCancellation()
        guard access(kind) == .authorized else { throw IntegrationError.unavailable }
        return value
    }
    /// Today uses local midnight boundaries; upcoming covers seven local calendar days, including today.
    func events(for route: Route, now: Date = Date(), calendar: Calendar = .current) async throws -> [AgendaEvent] {
        guard calendarEnabled, access(.calendar) == .authorized, !calendarIDs.isEmpty else { return [] }
        let days: Int
        switch route { case .today: days = 1; case .upcoming: days = 7; default: return [] }
        let start = calendar.startOfDay(for: now)
        guard let end = calendar.date(byAdding: .day, value: days, to: start) else { return [] }
        let token = revision, ids = calendarIDs
        let value = try await provider.events(start: start, end: end, ids: ids)
        try Task.checkCancellation()
        guard token == revision, calendarEnabled, access(.calendar) == .authorized else { return [] }
        return value.filter { $0.start < end && $0.end > start }.sorted { $0.start < $1.start }
    }
    func previewReminders() async throws -> [ReminderRecord] {
        guard access(.reminders) == .authorized, !reminderIDs.isEmpty else { return [] }
        let token = revision
        let value = try await provider.reminders(ids: reminderIDs)
        try Task.checkCancellation()
        guard token == revision, access(.reminders) == .authorized else { throw IntegrationError.unavailable }
        return value
    }
    /// Synchronous atomic import of the explicit preview selection; no EventKit writes or source deletion.
    @discardableResult func importReminders(_ records: [ReminderRecord], into store: TaskStore) throws -> Int {
        guard access(.reminders) == .authorized else { throw IntegrationError.unavailable }
        var known = Set(store.todos.filter { $0.source?.provider == "AppleReminders" }.compactMap { $0.source?.identifier })
        var todos: [Todo] = []
        for record in records where !record.id.isEmpty {
            guard known.insert(record.id).inserted else { continue }
            todos.append(Todo(title: record.title, notes: record.notes, deadline: record.due,
                              order: Double(store.todos.count + todos.count),
                              source: SourceInfo(provider: "AppleReminders", identifier: record.id)))
        }
        guard !todos.isEmpty else { return 0 }
        return try store.mergeImported(Snapshot(todos: todos)).added
    }
}
