import AppKit
import Carbon
import ShishiCore

/// Carbon 注册仅监听自己的热键，不读取其他应用键盘输入，也不要求辅助功能权限。
@MainActor
final class QuickEntryHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private(set) var errorText: String?
    init(action: @escaping () -> Void) { self.action = action }
    @discardableResult func register(_ shortcut: QuickEntryShortcut) -> Bool {
        stop()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x53534948, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<QuickEntryHotKey>.fromOpaque(context).takeUnretainedValue().action() }
            return noErr
        }, 1, &event, context, &handler)
        guard status == noErr else { stop(); errorText = "无法安装快捷键处理程序（\(status)）。"; return false }
        let id = EventHotKeyID(signature: 0x53534948, id: 1)
        let modifiers = shortcut == .controlOptionSpace ? controlKey | optionKey : controlKey | optionKey | cmdKey
        let key = shortcut == .controlOptionN ? kVK_ANSI_N : kVK_Space
        let registration = RegisterEventHotKey(UInt32(key), UInt32(modifiers), id, GetApplicationEventTarget(), 0, &hotKey)
        guard registration == noErr, hotKey != nil else {
            stop(); errorText = "快捷键登记失败，可能已被占用（\(registration)）。请更换组合或使用文件菜单。"; return false
        }
        errorText = nil; return true
    }
    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }; hotKey = nil
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

/// 应用正常启动后调用 start；初始化和手动 show 不登记热键。
@MainActor final class QuickEntryCoordinator: NSObject {
    static let changed = Notification.Name("ShishiQuickEntryCoordinatorChanged")
    let preferences: QuickEntryPreferences
    private let store: TaskStore
    private let currentRoute: () -> Route
    private var hotKey: QuickEntryHotKey?
    private var panel: QuickEntryPanel?
    private var started = false
    private(set) var statusText = "全局快捷键尚未启动；可使用试用按钮。" {
        didSet { NotificationCenter.default.post(name: Self.changed, object: self) }
    }
    init(store: TaskStore, currentRoute: @escaping () -> Route, defaults: UserDefaults? = nil) {
        self.store = store; self.currentRoute = currentRoute
        preferences = defaults.map { QuickEntryPreferences(defaults: $0) } ?? .shared
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged), name: QuickEntryPreferences.changed, object: preferences)
    }
    /// QA / XCTest 强制跳过 Carbon 登记；主代理仍应只在正常启动 hook 调用。
    func start() {
        guard !CommandLine.arguments.contains(where: { $0.hasPrefix("--qa") || $0.contains(".xctest") }),
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            registrationStatus = "QA / 测试模式：未登记全局快捷键。"
            statusText = registrationStatus; return
        }
        started = true; refreshRegistration()
    }
    @objc func show() {
        if panel == nil {
            panel = QuickEntryPanel(store: store, currentRoute: currentRoute, preferences: preferences)
            panel?.saved = { [weak self] message in
                guard let self else { return }
                self.statusText = self.registrationStatus + " " + message
            }
        }
        panel?.present()
    }
    func stop() {
        started = false; hotKey?.stop(); hotKey = nil; panel?.cancelDraft()
        registrationStatus = "全局快捷键已停止；可使用文件菜单。"
        statusText = registrationStatus
    }
    /// 退出前检查显示中和已隐藏的草稿。无内容、保存成功或明确丢弃返回 true；
    /// 默认取消、空标题和写盘失败返回 false，保留未提交内容。
    func prepareToTerminate() -> Bool { panel?.prepareToTerminate() ?? true }
    @objc private func preferencesChanged() { if started { refreshRegistration() } }
    private var registrationStatus = "全局快捷键尚未启动。"
    private func refreshRegistration() {
        hotKey?.stop(); hotKey = nil
        guard preferences.enabled else {
            registrationStatus = "全局快捷键已关闭；可使用文件菜单或试用按钮。"
            statusText = registrationStatus; return
        }
        let key = QuickEntryHotKey { [weak self] in self?.show() }; hotKey = key
        registrationStatus = key.register(preferences.shortcut) ? "已登记 \(preferences.shortcut.title)。" : (key.errorText ?? "快捷键登记失败。")
        statusText = registrationStatus
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}
