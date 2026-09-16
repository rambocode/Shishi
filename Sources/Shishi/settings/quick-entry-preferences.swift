import Foundation

enum QuickEntryDestination: String, CaseIterable {
    case inbox, today, currentList
    var title: String {
        switch self { case .inbox: return "收件箱"; case .today: return "今天"; case .currentList: return "当前列表" }
    }
}
/// 预设真实的多修饰键组合，不提供伪录制输入框。
enum QuickEntryShortcut: String, CaseIterable {
    case controlOptionSpace, controlOptionN, controlOptionCommandSpace
    var title: String {
        switch self {
        case .controlOptionSpace: return "⌃⌥Space"
        case .controlOptionN: return "⌃⌥⌘N"
        case .controlOptionCommandSpace: return "⌃⌥⌘Space"
        }
    }
}
@MainActor final class QuickEntryPreferences: NSObject {
    static let shared = QuickEntryPreferences(defaults: .standard)
    static let changed = Notification.Name("ShishiQuickEntryPreferencesChanged")
    private let defaults: UserDefaults
    private static let prefix = "Shishi.quickEntry."
    var enabled: Bool { didSet { persist() } }
    var shortcut: QuickEntryShortcut { didSet { persist() } }
    var destination: QuickEntryDestination { didSet { persist() } }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        enabled = (defaults.object(forKey: Self.prefix + "enabled") as? Bool) ?? true
        shortcut = QuickEntryShortcut(rawValue: defaults.string(forKey: Self.prefix + "shortcut") ?? "") ?? .controlOptionSpace
        destination = QuickEntryDestination(rawValue: defaults.string(forKey: Self.prefix + "destination") ?? "") ?? .inbox
        super.init()
    }
    private func persist() {
        defaults.set(enabled, forKey: Self.prefix + "enabled")
        defaults.set(shortcut.rawValue, forKey: Self.prefix + "shortcut")
        defaults.set(destination.rawValue, forKey: Self.prefix + "destination")
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}
