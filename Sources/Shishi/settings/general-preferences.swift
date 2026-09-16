import Foundation
import ShishiCore

@MainActor final class GeneralPreferences {
    static let shared = GeneralPreferences()
    static let changed = Notification.Name("ShishiGeneralPreferencesChanged")
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private func write(_ value: Any, key: String) {
        defaults.set(value, forKey: key)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
    var appearance: Int {
        get { let n = defaults.integer(forKey: "appearance"); return (0...2).contains(n) ? n : 0 }
        set { let n = min(2, max(0, newValue)); if n != appearance { write(n, key: "appearance") } }
    }
    var textSize: Int {
        get { defaults.object(forKey: "textSize") == nil ? 14 : min(20, max(11, defaults.integer(forKey: "textSize"))) }
        set { let n = min(20, max(11, newValue)); if n != textSize { write(n, key: "textSize") } }
    }
    var groupToday: Bool {
        get { defaults.object(forKey: "groupToday") == nil ? true : defaults.bool(forKey: "groupToday") }
        set { if newValue != groupToday { write(newValue, key: "groupToday") } }
    }
    var archiveTiming: ArchiveTiming {
        get { defaults.string(forKey: "archiveTiming").flatMap(ArchiveTiming.init(rawValue:)) ?? .immediately }
        set { if newValue != archiveTiming { write(newValue.rawValue, key: "archiveTiming") } }
    }
    var dockCount: DockCountMode {
        get { defaults.string(forKey: "dockCount").flatMap(DockCountMode.init(rawValue:)) ?? .none }
        set { if newValue != dockCount { write(newValue.rawValue, key: "dockCount") } }
    }
}
