import AppKit
import ShishiCore

@main
enum ShishiApplication {
    @MainActor static func main() {
        if ImportCommand.runIfRequested(CommandLine.arguments) { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowController?
    private var dockCounter: DockCounter?
    private var libraryLock: LibraryLock?
    private var focusAppearance: FocusAppearance?
    private var taskNotifications: TaskNotifications?

    func applicationDidFinishLaunching(_ notification: Notification) {
        focusAppearance = FocusAppearance()
        let args = CommandLine.arguments
        let dataURL: URL
        if let index = args.firstIndex(of: "--data-path"), args.indices.contains(index + 1) {
            dataURL = URL(fileURLWithPath: args[index + 1]).standardizedFileURL.resolvingSymlinksInPath()
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dataURL = base.appendingPathComponent("Shishi", isDirectory: true).appendingPathComponent(args.contains("--demo") ? "demo.json" : "library.json")
        }
        do { libraryLock = try LibraryLock(dataURL: dataURL) }
        catch {
            let alert = NSAlert(); alert.messageText = "无法打开拾事"; alert.informativeText = error.localizedDescription
            alert.runModal(); NSApp.terminate(nil); return
        }
        let store = TaskStore(fileURL: dataURL, demo: args.contains("--demo"))
        let controller = MainWindowController(store: store, dataURL: dataURL)
        mainWindow = controller
        let notifications = TaskNotifications(store: store)
        taskNotifications = notifications
        if !args.contains("--qa") { notifications.start() }
        controller.list.onReminderSaved = { [weak notifications] in
            guard !args.contains("--qa") else { return }
            Task { @MainActor in
                if let message = await notifications?.authorizeAndRefresh() {
                    let alert = NSAlert(); alert.messageText = "提醒已保存"
                    alert.informativeText = message; alert.addButton(withTitle: "好")
                    alert.runModal()
                }
            }
        }
        dockCounter = DockCounter(store: store)
        SettingsController.applyTheme()
        makeMenu(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        if store.errorMessage != nil { controller.showStoreError() }
        if !args.contains("--qa") {
            controller.quickEntryCoordinator.start()
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow?.showWindow(nil); mainWindow?.window?.makeKeyAndOrderFront(nil); return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard mainWindow?.prepareToClose() != false else { return .terminateCancel }
        return mainWindow?.quickEntryCoordinator.prepareToTerminate() == false ? .terminateCancel : .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) { mainWindow?.quickEntryCoordinator.stop() }

    private func makeMenu(_ controller: MainWindowController) {
        let main = NSMenu()
        let app = NSMenu(title: "拾事")
        add(app, "关于拾事", #selector(about), target: self)
        app.addItem(.separator())
        add(app, "设置…", #selector(MainWindowController.showSettings), key: ",", target: controller)
        app.addItem(.separator())
        add(app, "隐藏拾事", #selector(NSApplication.hide(_:)), key: "h", target: NSApp)
        add(app, "退出拾事", #selector(NSApplication.terminate(_:)), key: "q", target: NSApp)
        append(app, to: main)
        let file = NSMenu(title: "文件")
        add(file, "新建待办事项", #selector(MainWindowController.newTask), key: "n", target: controller)
        add(file, "快速录入…", #selector(MainWindowController.quickEntry), key: " ", modifiers: [.command, .option], target: controller)
        add(file, "新建标题 / 项目…", #selector(MainWindowController.newHeadingOrProject), key: "n", modifiers: [.command, .shift], target: controller)
        add(file, "新建项目…", #selector(MainWindowController.newProject), target: controller)
        add(file, "新建区域…", #selector(MainWindowController.newArea), key: "n", modifiers: [.command, .option], target: controller)
        file.addItem(.separator())
        add(file, "从 Things 3 导入…", #selector(MainWindowController.importThings), target: controller)
        add(file, "导出备份…", #selector(MainWindowController.exportData), target: controller)
        add(file, "恢复备份…", #selector(MainWindowController.importData), target: controller)
        file.addItem(.separator())
        add(file, "关闭窗口", #selector(NSWindow.performClose(_:)), key: "w")
        append(file, to: main)
        let edit = NSMenu(title: "编辑")
        add(edit, "撤销", #selector(MainWindowController.undoStore), key: "z", target: controller)
        add(edit, "重做", #selector(MainWindowController.redoStore), key: "z", modifiers: [.command, .shift], target: controller)
        edit.addItem(.separator())
        add(edit, "剪切", #selector(NSText.cut(_:)), key: "x")
        add(edit, "复制", #selector(NSText.copy(_:)), key: "c")
        add(edit, "粘贴", #selector(NSText.paste(_:)), key: "v")
        add(edit, "全选", #selector(MainWindowController.selectAllItems), key: "a", target: controller)
        edit.addItem(.separator())
        add(edit, "快速查找", #selector(MainWindowController.focusSearch), key: "f", target: controller)
        append(edit, to: main)
        let view = NSMenu(title: "查看")
        let routes: [(String, Selector)] = [
            ("收件箱", #selector(MainWindowController.inbox)), ("今天", #selector(MainWindowController.today)),
            ("计划", #selector(MainWindowController.upcoming)), ("随时", #selector(MainWindowController.anytime)),
            ("某天", #selector(MainWindowController.someday)), ("日志簿", #selector(MainWindowController.logbook)),
            ("废纸篓", #selector(MainWindowController.trashView))
        ]
        for (index, entry) in routes.enumerated() { add(view, entry.0, entry.1, key: String(index + 1), target: controller) }
        view.addItem(.separator())
        add(view, "显示 / 隐藏边栏", #selector(MainWindowController.toggleSidebar), key: "/", target: controller)
        append(view, to: main)
        // 「项」菜单键位对齐 Things 3：同一动作在两个应用里按同一组键完成。
        let item = NSMenu(title: "项")
        add(item, "时间…", #selector(MainWindowController.showSchedule), key: "s", target: controller)
        add(item, "移动…", #selector(MainWindowController.showMove), key: "m", modifiers: [.command, .shift], target: controller)
        add(item, "标签…", #selector(MainWindowController.showTags), key: "t", modifiers: [.command, .shift], target: controller)
        add(item, "截止日期…", #selector(MainWindowController.showDeadline), key: "d", modifiers: [.command, .shift], target: controller)
        item.addItem(.separator())
        let completion = NSMenu(title: "完成")
        add(completion, "标记为已完成 / 重新打开", #selector(MainWindowController.completeSelected), key: "k", target: controller)
        add(completion, "标记为已取消", #selector(MainWindowController.cancelSelected), key: "k", modifiers: [.command, .option], target: controller)
        append(completion, to: item)
        // 捷径使用无修饰单键，靠 validateMenuItem 在文本输入与编辑态关闭，避免抢字符输入。
        let shortcuts = NSMenu(title: "捷径")
        add(shortcuts, "今天", #selector(MainWindowController.scheduleToday), key: "t", modifiers: [], target: controller)
        add(shortcuts, "今晚", #selector(MainWindowController.scheduleEvening), key: "e", modifiers: [], target: controller)
        add(shortcuts, "某天", #selector(MainWindowController.scheduleSomeday), key: "o", modifiers: [], target: controller)
        add(shortcuts, "清除", #selector(MainWindowController.scheduleClear), key: "r", modifiers: [], target: controller)
        append(shortcuts, to: item)
        item.addItem(.separator())
        add(item, "复制", #selector(MainWindowController.duplicateSelected), key: "d", target: controller)
        add(item, "归档已完成项", #selector(MainWindowController.archiveCompleted), key: "y", modifiers: [.command, .shift], target: controller)
        add(item, "移到废纸篓", #selector(MainWindowController.deleteSelected), key: String(UnicodeScalar(NSDeleteCharacter)!), target: controller)
        append(item, to: main)
        let window = NSMenu(title: "窗口")
        add(window, "最小化", #selector(NSWindow.performMiniaturize(_:)), key: "m")
        add(window, "缩放", #selector(NSWindow.performZoom(_:)))
        append(window, to: main); NSApp.windowsMenu = window
        let help = NSMenu(title: "帮助")
        add(help, "拾事使用帮助", #selector(showHelp), target: self)
        append(help, to: main)
        NSApp.mainMenu = main
    }
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers; item.target = target; menu.addItem(item)
    }
    private func append(_ menu: NSMenu, to main: NSMenu) {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu; main.addItem(item)
    }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "拾事", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版", .version: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            .credits: NSAttributedString(string: "原生 AppKit 待办应用\n独立实现 · 本地优先")])
    }
    @objc private func showHelp() {
        if let url = Bundle.main.url(forResource: "help", withExtension: "html") { NSWorkspace.shared.open(url) }
    }
}
