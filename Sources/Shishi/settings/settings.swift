import AppKit

/// 切换设置页面不重建主窗口，也不隐式提交任务草稿。
@MainActor
final class SettingsController: NSWindowController, NSToolbarDelegate {
    enum Page: String, CaseIterable {
        case general, cloud, quickEntry, reminders, calendars, data
        var title: String {
            switch self {
            case .general: return "常规"
            case .cloud: return "云同步"
            case .quickEntry: return "快速输入"
            case .reminders: return "提醒事项"
            case .calendars: return "日历"
            case .data: return "数据与备份"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .cloud: return "cloud"
            case .quickEntry: return "plus.app"
            case .reminders: return "list.bullet.rectangle"
            case .calendars: return "calendar"
            case .data: return "externaldrive"
            }
        }
    }
    private let dataURL: URL
    private weak var mainController: MainWindowController?
    private var pages: [Page: NSViewController] = [:]
    private(set) var selectedPage: Page = .general

    init(dataURL: URL, owner: MainWindowController) {
        self.dataURL = dataURL; self.mainController = owner
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 490),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "常规"; window.isReleasedWhenClosed = false; window.toolbarStyle = .preference
        super.init(window: window)
        let toolbar = NSToolbar(identifier: "settings-toolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconAndLabel; toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        select(.general); window.center()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func select(_ page: Page) {
        guard let owner = mainController else { return }
        if pages[page] == nil {
            switch page {
            case .general: pages[page] = GeneralSettingsPane(store: owner.store)
            case .cloud: pages[page] = CloudSettingsPane()
            case .quickEntry: pages[page] = QuickEntrySettingsPane(coordinator: owner.quickEntryCoordinator)
            case .reminders: pages[page] = RemindersSettingsPane(service: .shared, store: owner.store)
            case .calendars: pages[page] = CalendarSettingsPane(service: .shared)
            case .data: pages[page] = DataSettingsPane(dataURL: dataURL, owner: owner)
            }
        }
        selectedPage = page; window?.contentViewController = pages[page]
        window?.setContentSize(NSSize(width: 600, height: 490)); window?.title = page.title
        window?.toolbar?.selectedItemIdentifier = .init(page.rawValue)
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Page.allCases.map { .init($0.rawValue) } }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarAllowedItemIdentifiers(toolbar) }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let page = Page(rawValue: id.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = page.title; item.toolTip = page.title + "设置"
        item.image = NSImage(systemSymbolName: page.symbol, accessibilityDescription: page.title)
        item.target = self; item.action = #selector(changePage(_:)); return item
    }
    @objc private func changePage(_ sender: NSToolbarItem) {
        if let page = Page(rawValue: sender.itemIdentifier.rawValue) { select(page) }
    }
    static func applyTheme() {
        Appearance.apply(.shared)
    }
}
