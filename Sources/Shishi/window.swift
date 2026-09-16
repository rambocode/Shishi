import AppKit
import ShishiCore

@MainActor
final class MainWindowController: NSWindowController, NSSearchFieldDelegate, NSToolbarDelegate, NSMenuItemValidation, NSWindowDelegate {
    let store: TaskStore
    let dataURL: URL
    private let split = NSSplitViewController()
    private let sidebar: SidebarController
    let list: TaskListController
    private let search = NSSearchField()
    private var route: Route = .today
    private var sheetController: NSViewController?
    private var lastNonSearchRoute: Route = .today
    private var settingsController: SettingsController?
    private var errorObserver: NSObjectProtocol?
    private var thingsImporter: ThingsImportCoordinator?
    private var isEditingInline = false
    lazy var quickEntryCoordinator = QuickEntryCoordinator(store: store, currentRoute: { [weak self] in self?.route ?? .inbox })

    init(store: TaskStore, dataURL: URL) {
        self.store = store; self.dataURL = dataURL
        sidebar = SidebarController(store: store)
        list = TaskListController(store: store)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "拾事"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unified
        window.minSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180; sidebarItem.maximumThickness = 300
        sidebarItem.preferredThicknessFraction = 0.21
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: list))
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1080, height: 720))
        split.splitView.setPosition(220, ofDividerAt: 0)
        if CommandLine.arguments.contains("--qa-small-window") {
            window.setFrame(NSRect(x: 80, y: 80, width: 760, height: 560), display: false)
        }
        sidebar.onSelect = { [weak self] route in self?.navigate(route) }
        sidebar.onNewProject = { [weak self] in self?.newProject() }
        sidebar.onNewArea = { [weak self] in self?.newArea() }
        sidebar.onEditProject = { [weak self] id in self?.editProject(id) }
        sidebar.onSettings = { [weak self] in self?.showSettings() }
        list.onEditTask = { [weak self] id in self?.editTask(id) }
        list.onNewTask = { [weak self] in self?.newTask() }
        list.onEditProject = { [weak self] id in self?.editProject(id) }
        list.onNavigate = { [weak self] destination in self?.navigate(destination) }
        list.onSearch = { [weak self] in self?.focusSearch() }
        list.onInlineEditingChanged = { [weak self] editing in self?.isEditingInline = editing }
        list.onRouteChangeBlocked = { [weak self] actual in self?.route = actual; self?.sidebar.select(actual) }
        search.placeholderString = "快速查找"
        search.focusRingType = .none
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.setAccessibilityLabel("快速查找")
        search.setAccessibilityIdentifier("quick-search")
        search.frame.size = NSSize(width: 200, height: 24)
        let toolbar = NSToolbar(identifier: "main-toolbar")
        toolbar.delegate = self; toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.center()
        if !CommandLine.arguments.contains("--qa") { window.setFrameAutosaveName("ShishiMainWindow") }
        navigate(CommandLine.arguments.contains("--qa") ? .today : RoutePreferences.restore(store: store))
        errorObserver = NotificationCenter.default.addObserver(forName: .init("ShishiStoreFailed"), object: store, queue: .main) { [weak self] _ in
            // 保存按钮所在sheet有自己的错误反馈；列表直接操作则由窗口提示。
            DispatchQueue.main.async {
                guard self?.window?.attachedSheet == nil, self?.isEditingInline == false, NSApp.modalWindow == nil else { return }
                self?.showStoreError()
            }
        }
    }
    deinit { if let errorObserver { NotificationCenter.default.removeObserver(errorObserver) } }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, .init("search")]
    }
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, .init("search")]
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard id.rawValue == "search" else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = "快速查找"; item.view = search
        return item
    }
    func controlTextDidChange(_ obj: Notification) {
        let wasEditing = isEditingInline
        let selection = search.currentEditor()?.selectedRange
        guard list.finishInlineEditing() else { return }
        if wasEditing {
            window?.makeFirstResponder(search)
            if let selection { search.currentEditor()?.selectedRange = selection }
        }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        route = query.isEmpty ? lastNonSearchRoute : .search(query)
        list.route = route
    }
    func navigate(_ newRoute: Route) {
        guard list.finishInlineEditing() else { sidebar.select(route); return }
        route = newRoute; lastNonSearchRoute = newRoute; search.stringValue = ""
        list.route = newRoute; sidebar.select(newRoute)
        if !CommandLine.arguments.contains("--qa") { RoutePreferences.save(newRoute) }
        window?.title = "\(Appearance.title(for: newRoute, store: store)) — 拾事"
    }
    @objc func focusSearch() {
        guard list.finishInlineEditing() else { return }
        window?.makeFirstResponder(search)
    }
    @objc func newTask() { createTask(in: route) }
    @objc func quickEntry() { quickEntryCoordinator.show() }
    @objc func archiveCompleted() { _ = store.archiveCompletedItems() }
    private func createTask(in route: Route) {
        guard window?.attachedSheet == nil else { return }
        guard list.finishInlineEditing() else { return }
        var todo = Todo(title: "")
        switch route {
        case .today: todo.schedule = .dated; todo.startDate = Calendar.current.startOfDay(for: Date())
        case .upcoming: todo.schedule = .dated; todo.startDate = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        case .anytime: todo.schedule = .anytime
        case .someday: todo.schedule = .someday
        case .project(let id):
            todo.projectID = id; todo.areaID = store.projects.first { $0.id == id }?.areaID; todo.schedule = .anytime
            todo.headingID = list.contextHeadingID
        case .area(let id): todo.areaID = id; todo.schedule = .anytime
        case .tag(let name): todo.tags = [name]
        default: break
        }
        if route == .trash || route == .logbook { navigate(.inbox) }
        list.beginEditing(todo, isNew: true)
    }
    func editTask(_ id: UUID) {
        guard let todo = store.todo(id), window?.attachedSheet == nil else { return }
        showEditor(todo: todo, isNew: false)
    }
    private func showEditor(todo: Todo, isNew: Bool) {
        let editor = TaskEditorController(store: store, todo: todo, isNew: isNew)
        editor.onFinish = { [weak self] id in
            self?.closeSheet()
            if let id { self?.list.reload(); self?.list.selectTask(id) }
        }
        presentSheet(editor, title: isNew ? "新建待办事项" : "编辑待办事项")
    }
    @objc func newProject() {
        var project = Project(title: "")
        if case .area(let id) = route { project.areaID = id }
        presentProject(project)
    }
    /// 保留全局新项目快捷键，在项目内部按截图语义创建标题分组。
    @objc func newHeadingOrProject() {
        if case .project = route { list.newHeading() }
        else { newProject() }
    }
    func editProject(_ id: UUID) {
        guard let project = store.projects.first(where: { $0.id == id }) else { return }
        presentProject(project)
    }
    private func presentProject(_ project: Project) {
        let editor = ProjectEditorController(store: store, project: project)
        editor.onFinish = { [weak self] id in self?.closeSheet(); if let id { self?.navigate(.project(id)) } }
        presentSheet(editor, title: "项目")
    }
    @objc func newArea() { presentArea(Area(title: "")) }
    private func presentArea(_ area: Area) {
        let editor = AreaEditorController(store: store, area: area)
        editor.onFinish = { [weak self] id in self?.closeSheet(); if let id { self?.navigate(.area(id)) } }
        presentSheet(editor, title: "区域")
    }
    private func presentSheet(_ controller: NSViewController, title: String) {
        guard let window, window.attachedSheet == nil else { return }
        guard list.finishInlineEditing() else { return }
        sheetController = controller
        let sheet = NSWindow(contentViewController: controller)
        sheet.title = title
        window.beginSheet(sheet)
    }
    private func closeSheet() {
        guard let window, let sheet = window.attachedSheet else { return }
        window.endSheet(sheet); sheet.orderOut(nil); sheetController = nil
    }
    @objc func completeSelected() {
        if list.selectedTaskIDs.count > 1 { list.completeSelection(); return }
        if let id = list.selectedTaskID { store.toggle(id) }
        else if let id = list.selectedProjectID, var project = store.projects.first(where: { $0.id == id }) {
            project.completed.toggle(); project.status = project.completed ? .completed : .open
            store.saveProject(project)
        }
    }
    @objc func cancelSelected() { list.cancelSelection() }
    @objc func duplicateSelected() { list.duplicateSelection() }
    @objc func deleteSelected() { list.deleteSelected() }
    @objc func showSchedule() { list.showScheduleForSelection() }
    @objc func showMove() { list.showMoveMenuForSelection() }
    @objc func showTags() { list.showTagsForSelection() }
    @objc func showDeadline() { list.showDeadlineForSelection() }
    @objc func scheduleToday() { list.applyQuickSchedule(.today) }
    @objc func scheduleEvening() { list.applyQuickSchedule(.evening) }
    @objc func scheduleSomeday() { list.applyQuickSchedule(.someday) }
    @objc func scheduleClear() { list.applyQuickSchedule(.clear) }
    @objc func toggleSidebar() { split.toggleSidebar(nil) }
    /// ⌘A 在文本输入里仍然是选中文本，只有焦点在主窗口列表时才变成全选待办。
    @objc func selectAllItems() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.selectAll(nil); return }
        if let text = NSApp.keyWindow?.firstResponder as? NSText { text.selectAll(nil); return }
        // 设置窗口等其他窗口在前时不得越窗全选主列表，交还标准响应链。
        guard NSApp.keyWindow === window else {
            NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSText.selectAll(_:)), with: nil); return
        }
        list.selectAllTasks()
    }

    /// 作用于选中待办的菜单命令的共同前置条件。
    /// 单键捷径靠这里在文本输入、卡片编辑、弹窗与非主窗口时失效，AppKit 才会把字符交还给输入框。
    private var canRunItemCommand: Bool {
        ItemCommandGate.allows(isMainWindowKey: NSApp.keyWindow === window,
                               hasSheet: window?.attachedSheet != nil,
                               hasModal: NSApp.modalWindow != nil,
                               isEditingInline: isEditingInline,
                               firstResponder: NSApp.keyWindow?.firstResponder)
    }
    @objc func undoStore() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.undo(); return }
        store.undo()
    }
    @objc func redoStore() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView { text.undoManager?.redo(); return }
        store.redo()
    }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(deleteSelected) { menuItem.title = route == .trash ? "永久删除…" : "移到废纸篓" }
        if menuItem.action == #selector(undoStore) {
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView { return text.undoManager?.canUndo ?? false }
            return window?.attachedSheet == nil && !isEditingInline && store.canUndo
        }
        if menuItem.action == #selector(redoStore) {
            if let text = NSApp.keyWindow?.firstResponder as? NSTextView { return text.undoManager?.canRedo ?? false }
            return window?.attachedSheet == nil && !isEditingInline && store.canRedo
        }
        if window?.attachedSheet != nil { return false }
        if menuItem.action == #selector(completeSelected) || menuItem.action == #selector(deleteSelected) {
            return (list.selectedTaskID != nil || list.selectedProjectID != nil) && !isEditingInline && !(NSApp.keyWindow?.firstResponder is NSTextView)
        }
        let selectionCommands: [Selector] = [
            #selector(showSchedule), #selector(showMove), #selector(showTags), #selector(showDeadline),
            #selector(scheduleToday), #selector(scheduleEvening), #selector(scheduleSomeday), #selector(scheduleClear),
            #selector(cancelSelected), #selector(duplicateSelected)
        ]
        if selectionCommands.contains(where: { $0 == menuItem.action }) {
            guard canRunItemCommand else { return false }
            // 复制允许作用于已完成项，其余命令只对开放待办有意义。
            if menuItem.action == #selector(duplicateSelected) { return !list.selectedTaskIDs.isEmpty }
            return list.canRunSelectionAction
        }
        return true
    }
    @objc func today() { navigate(.today) }
    @objc func inbox() { navigate(.inbox) }
    @objc func upcoming() { navigate(.upcoming) }
    @objc func anytime() { navigate(.anytime) }
    @objc func someday() { navigate(.someday) }
    @objc func logbook() { navigate(.logbook) }
    @objc func trashView() { navigate(.trash) }
    @objc func showSettings() {
        if settingsController == nil { settingsController = SettingsController(dataURL: dataURL, owner: self) }
        settingsController?.showWindow(nil); settingsController?.window?.makeKeyAndOrderFront(nil)
    }
    @objc func exportData() {
        guard list.finishInlineEditing() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "拾事备份-\(ISO8601DateFormatter().string(from: Date()).prefix(10)).json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.exportData(to: url) } catch { presentError("备份失败", error.localizedDescription) }
    }
    @objc func importData() {
        guard list.finishInlineEditing() else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert(); alert.messageText = "恢复此备份？"
        alert.informativeText = "当前数据库会先备份，然后以所选文件替换。请确认文件来源和内容。"
        alert.addButton(withTitle: "恢复备份"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try store.importData(from: url); navigate(.today) } catch { presentError("恢复失败", error.localizedDescription) }
    }
    @objc func importThings() {
        guard list.finishInlineEditing() else { return }
        let coordinator = ThingsImportCoordinator(store: store, window: window)
        coordinator.onFinish = { [weak self] in self?.navigate(.today) }
        thingsImporter = coordinator
        coordinator.chooseSource()
    }
    func prepareToClose() -> Bool {
        guard window?.attachedSheet == nil else { NSSound.beep(); return false }
        return list.finishInlineEditing()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { prepareToClose() }
    func showStoreError() {
        if let message = store.errorMessage { presentError("未能保存更改", message) }
    }
    private func presentError(_ title: String, _ detail: String) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = title; alert.informativeText = detail
        alert.runModal()
    }
}

/// 单键捷径（T/E/O/R）与其他选中项命令的启用判据。
/// 抽成独立类型是为了能在没有真实 keyWindow 的测试环境里直接验证 INV-3：
/// 只要焦点在文本里、卡片在编辑、有 sheet/modal 或主窗口不是 key，命令必须禁用，
/// 否则 AppKit 会把字符当快捷键吃掉，用户就打不出 t、e、o、r。
enum ItemCommandGate {
    static func allows(isMainWindowKey: Bool, hasSheet: Bool, hasModal: Bool,
                       isEditingInline: Bool, firstResponder: NSResponder?) -> Bool {
        guard isMainWindowKey, !hasSheet, !hasModal, !isEditingInline else { return false }
        if firstResponder is NSTextView { return false }
        if let field = firstResponder as? NSTextField, field.isEditable { return false }
        return true
    }
}
