import AppKit
import ShishiCore

@MainActor final class DockCounter {
    private weak var store: TaskStore?
    private let preferences: GeneralPreferences
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var day = Calendar.current.startOfDay(for: Date())
    private var archiveRetry = false
    convenience init(store: TaskStore) { self.init(store: store, preferences: .shared) }
    init(store: TaskStore, preferences: GeneralPreferences) {
        self.store = store; self.preferences = preferences
        for (name, object) in [(TaskStore.changed, store as AnyObject), (GeneralPreferences.changed, preferences as AnyObject)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDay() }
        })
        // 定时复核覆盖睡眠恢复、时区变化；不读取任何其他应用。
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDay() }
        }
        refresh()
    }
    deinit { timer?.invalidate(); observers.forEach { NotificationCenter.default.removeObserver($0) } }
    func refreshDay(now: Date = Date()) {
        let next = Calendar.current.startOfDay(for: now)
        if next != day || archiveRetry {
            let changedDay = next != day
            day = next
            archiveRetry = store?.refreshArchiveTiming(now: now) == false
            if changedDay, let store { NotificationCenter.default.post(name: TaskStore.changed, object: store) }
        }
        refresh(now: now)
    }
    func refresh(now: Date = Date()) {
        guard let store else { return }
        let count = DockCounts.count(in: store.snapshot, mode: preferences.dockCount, now: now)
        // 测试/CLI 不创建 NSApplication；真实运行时 Store 持有该服务。
        NSApp?.dockTile.badgeLabel = count == 0 ? nil : String(count)
        Appearance.apply(preferences)
    }
}
