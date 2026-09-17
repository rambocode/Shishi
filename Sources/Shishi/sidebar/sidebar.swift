import AppKit
import ShishiCore

private struct SidebarEntry {
    var route: Route?
    var title: String
    var symbol: String = ""
    var color: NSColor = .secondaryLabelColor
    var indent: CGFloat = 0
    var spacer: Bool = false
}

private final class AreaDisclosureButton: NSButton {
    var areaID: UUID?
}

/// 纯色侧栏底；外观切换时重绘，深色模式由 Appearance.sidebarBackground 自动换色。
private final class SidebarBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        Appearance.sidebarBackground.setFill()
        dirtyRect.fill()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}

/// 侧栏选中行用品牌蓝绘制；系统 source list 的选中色跟随系统强调色，明度过高。
private final class SidebarRowView: NSTableRowView {
    // source list 样式的选中由系统材质绘制、不会调用 drawSelection；固定为 regular 才能自绘品牌蓝。
    override var selectionHighlightStyle: NSTableView.SelectionHighlightStyle {
        get { .regular }
        set { }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        Appearance.blue.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 6, yRadius: 6).fill()
    }
    // 选中时保持白字，与品牌蓝底对比清楚。
    override var interiorBackgroundStyle: NSView.BackgroundStyle { isSelected ? .emphasized : .normal }
}

@MainActor
final class SidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    let store: TaskStore
    var onSelect: ((Route) -> Void)?
    var onNewProject: (() -> Void)?
    var onNewArea: (() -> Void)?
    var onEditProject: ((UUID) -> Void)?
    var onSettings: (() -> Void)?
    var route: Route = .today
    private var rows: [SidebarEntry] = []
    private let table = NSTableView()
    private var token: NSObjectProtocol?
    private var preferencesToken: NSObjectProtocol?
    private var collapsedAreas = Set(UserDefaults.standard.stringArray(forKey: "collapsedAreas") ?? [])
    /// 正在行内改名的区域或项目；改名期间禁止重建行，否则输入会被打断。
    private var editingRoute: Route?
    private var pendingReload = false

    init(store: TaskStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
        if let preferencesToken { NotificationCenter.default.removeObserver(preferencesToken) }
    }

    override func loadView() {
        // 左侧面板用固定底色 #F9F9FA，不再用系统半透明材质（会透出桌面、色调不稳定）。
        let background = SidebarBackgroundView()
        view = background
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        table.addTableColumn(NSTableColumn(identifier: .init("sidebar")))
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .sourceList
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.delegate = self; table.dataSource = self
        table.target = self; table.doubleAction = #selector(renameSelection)
        table.registerForDraggedTypes([.init("app.local.shishi.task")])
        table.setAccessibilityLabel("列表导航")
        scroll.documentView = table
        background.addSubview(scroll)
        let footer = NSView()
        background.addSubview(footer)
        let newList = NSButton(title: "新建列表", target: self, action: #selector(showNewList(_:)))
        newList.image = Appearance.symbol("plus", description: "新建列表")
        newList.imagePosition = .imageLeading; newList.isBordered = false
        newList.font = .systemFont(ofSize: 12)
        newList.setAccessibilityIdentifier("new-list")
        let settings = NSButton(image: Appearance.symbol("slider.horizontal.3", description: "设置")!, target: self, action: #selector(settingsAction))
        settings.isBordered = false; settings.toolTip = "设置与备份"
        footer.addSubview(newList); footer.addSubview(settings)
        [scroll, footer, newList, settings].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: background.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor),
            footer.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: background.bottomAnchor), footer.heightAnchor.constraint(equalToConstant: 44),
            newList.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 16), newList.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            settings.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -14), settings.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])
        let menu = NSMenu()
        menu.addItem(withTitle: "编辑列表…", action: #selector(editSelection), keyEquivalent: "").target = self
        menu.addItem(withTitle: "删除列表…", action: #selector(deleteSelection), keyEquivalent: "").target = self
        table.menu = menu
        token = NotificationCenter.default.addObserver(forName: TaskStore.changed, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
        preferencesToken = NotificationCenter.default.addObserver(forName: GeneralPreferences.changed, object: store.preferences, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func reload() {
        guard isViewLoaded else { return }
        guard editingRoute == nil else { pendingReload = true; return }
        rows = [
            .init(route: .inbox, title: "收件箱", symbol: "tray.fill", color: Appearance.blue),
            .init(route: nil, title: "", spacer: true),
            .init(route: .today, title: "今天", symbol: "star.fill", color: .systemYellow),
            .init(route: .upcoming, title: "计划", symbol: "calendar", color: .systemPink),
            .init(route: .anytime, title: "随时", symbol: "square.stack.3d.up.fill", color: .systemTeal),
            .init(route: .someday, title: "某天", symbol: "archivebox.fill", color: .systemBrown),
            .init(route: nil, title: "", spacer: true),
            .init(route: .logbook, title: "日志簿", symbol: "checkmark.square.fill", color: .systemGreen),
            .init(route: .trash, title: "废纸篓", symbol: "trash.fill")
        ]
        let projects = store.projects.filter {
            ((!$0.completed && ($0.status == nil || $0.status == .open)) || $0.pendingArchiveDate != nil) && $0.deletedAt == nil
        }.sorted { $0.order < $1.order }
        for project in projects where project.areaID == nil {
            if rows.last?.route == .trash { rows.append(.init(route: nil, title: "", spacer: true)) }
            rows.append(.init(route: .project(project.id), title: project.title, symbol: "circle"))
        }
        for area in store.areas.sorted(by: { $0.order < $1.order }) {
            rows.append(.init(route: nil, title: "", spacer: true))
            rows.append(.init(route: .area(area.id), title: area.title, symbol: "square.stack.3d.up"))
            for project in projects where project.areaID == area.id && !collapsedAreas.contains(area.id.uuidString) {
                rows.append(.init(route: .project(project.id), title: project.title, symbol: "circle", indent: 8))
            }
        }
        if !store.allTags.isEmpty {
            rows.append(.init(route: nil, title: "", spacer: true))
            for tag in store.allTags { rows.append(.init(route: .tag(tag), title: tag, symbol: "tag")) }
        }
        table.reloadData()
        synchronizeSelection()
    }

    /// 路由切换只更新选择；计数、进度和行内容由数据及偏好变化触发 reload。
    private func synchronizeSelection() {
        if let row = rows.firstIndex(where: { $0.route == route }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            // 历史项目可从日志簿打开，但侧栏不应残留另一项目的选择高亮。
            table.deselectAll(nil)
        }
    }
    func select(_ newRoute: Route) {
        route = newRoute; synchronizeSelection()
        if table.selectedRow >= 0 { table.scrollRowToVisible(table.selectedRow) }
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard rows.indices.contains(row), let destination = rows[row].route,
              info.draggingPasteboard.string(forType: .init("app.local.shishi.task")) != nil else { return [] }
        switch destination { case .search, .logbook, .trash: return []; default: break }
        tableView.setDropRow(row, dropOperation: .on)
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard rows.indices.contains(row), let destination = rows[row].route,
              let raw = info.draggingPasteboard.string(forType: .init("app.local.shishi.task")),
              let id = UUID(uuidString: raw), store.todo(id) != nil else { return false }
        store.move(id, to: destination)
        return store.errorMessage == nil
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { SidebarRowView() }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].spacer ? 19 : max(29, CGFloat(store.preferences.textSize) + 15) }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].route != nil }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard rows.indices.contains(table.selectedRow), let selected = rows[table.selectedRow].route, selected != route else { return }
        route = selected; onSelect?(selected)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
        let cell = NSTableCellView()
        guard !entry.spacer else { return cell }
        let icon: NSView
        if case .project(let id) = entry.route, let project = store.projects.first(where: { $0.id == id }) {
            let progress = ProjectProgressView()
            progress.configure(project: project, summary: ProjectSummary(project: project, tasks: store.todos))
            icon = progress
        } else {
            let image = NSImageView()
            image.image = Appearance.symbol(entry.symbol, description: entry.title)
            image.contentTintColor = entry.color
            icon = image
        }
        let label = Appearance.label(entry.title, size: CGFloat(store.preferences.textSize))
        let count = entry.route.map { route -> Int in
            if case .project = route { return store.items(for: route).count }
            return store.items(for: route).count + store.projectItems(for: route).count
        } ?? 0
        let badge = Appearance.label(count > 0 ? String(count) : "", size: 11)
        badge.textColor = .tertiaryLabelColor
        [icon, label, badge].forEach { cell.addSubview($0); $0.translatesAutoresizingMaskIntoConstraints = false }
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var leading = 5 + entry.indent
        if case .area(let id) = entry.route {
            let toggle = AreaDisclosureButton()
            toggle.areaID = id; toggle.target = self; toggle.action = #selector(toggleArea(_:)); toggle.isBordered = false
            let collapsed = collapsedAreas.contains(id.uuidString)
            toggle.image = Appearance.symbol(collapsed ? "chevron.right" : "chevron.down", description: collapsed ? "展开区域" : "折叠区域")
            toggle.contentTintColor = .tertiaryLabelColor
            toggle.setAccessibilityLabel((collapsed ? "展开区域：" : "折叠区域：") + entry.title)
            cell.addSubview(toggle); toggle.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                toggle.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 0), toggle.widthAnchor.constraint(equalToConstant: 14),
                toggle.heightAnchor.constraint(equalToConstant: 22), toggle.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            leading = 18
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading), icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 17), icon.heightAnchor.constraint(equalToConstant: 17),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7), label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8), badge.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -6)
        ])
        cell.textField = label; cell.imageView = icon as? NSImageView
        cell.setAccessibilityLabel("\(entry.title)，\(count) 个事项")
        return cell
    }
    @objc private func toggleArea(_ sender: AreaDisclosureButton) {
        guard let id = sender.areaID?.uuidString else { return }
        if collapsedAreas.contains(id) { collapsedAreas.remove(id) } else { collapsedAreas.insert(id) }
        UserDefaults.standard.set(Array(collapsedAreas).sorted(), forKey: "collapsedAreas")
        reload()
    }
    @objc private func showNewList(_ sender: NSButton) {
        let menu = NSMenu()
        menu.addItem(withTitle: "新建项目…", action: #selector(newProject), keyEquivalent: "").target = self
        menu.addItem(withTitle: "新建区域…", action: #selector(newArea), keyEquivalent: "").target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
    @objc private func newProject() { onNewProject?() }
    @objc private func newArea() { onNewArea?() }
    @objc private func settingsAction() { onSettings?() }
    private var contextRoute: Route? {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        return rows.indices.contains(row) ? rows[row].route : nil
    }
    /// 右键“编辑列表…”：项目仍打开完整编辑器（备注、区域、日期等），区域只有名称，直接行内改名。
    @objc private func editSelection() {
        switch contextRoute {
        case .project(let id): onEditProject?(id)
        case .area: renameSelection()
        default: break
        }
    }

    /// 双击区域或项目：在侧栏行内改名，不弹出编辑窗口。
    @objc private func renameSelection() {
        guard let route = contextRoute else { return }
        beginRename(route)
    }

    /// 让指定区域或项目的侧栏标签变成输入框并全选名称；其它列表不可改名。
    func beginRename(_ route: Route) {
        let exists: Bool
        switch route {
        case .area(let id): exists = store.areas.contains { $0.id == id }
        case .project(let id): exists = store.projects.contains { $0.id == id && $0.deletedAt == nil }
        default: return
        }
        guard editingRoute == nil, exists,
              let row = rows.firstIndex(where: { $0.route == route }),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { return }
        editingRoute = route
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        // 侧栏标签默认会换行，字段编辑器里 Return 就只是换行；单行模式才让 Return 提交改名。
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = self
        if case .project = route { field.setAccessibilityLabel("项目名称") } else { field.setAccessibilityLabel("区域名称") }
        table.window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let route = editingRoute else { return }
        finishRename(route, field: field, title: field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // 输入法候选期间的按键全部交还给输入法，否则中文名字会被提前提交或取消。
        guard let field = control as? NSTextField, let route = editingRoute, !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            finishRename(route, field: field, title: nil)
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finishRename(route, field: field, title: field.stringValue)
            return true
        }
        return false
    }

    /// title 为 nil 表示取消。空名称、未改动和保存失败都回到原名称，不写入数据库。
    private func finishRename(_ route: Route, field: NSTextField, title: String?) {
        editingRoute = nil
        field.isEditable = false
        field.isSelectable = false
        field.isBezeled = false
        field.drawsBackground = false
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.delegate = nil
        if table.window?.firstResponder !== table { table.window?.makeFirstResponder(table) }
        pendingReload = false
        let name = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        // 保存成功由 Store 的变更通知触发刷新；失败时错误信息已由 Store 统一呈现。
        switch route {
        case .area(let id):
            guard var area = store.areas.first(where: { $0.id == id }), title != nil, !name.isEmpty, name != area.title else { reload(); return }
            area.title = name
            if !store.saveArea(area) { reload() }
        case .project(let id):
            guard var project = store.projects.first(where: { $0.id == id }), title != nil, !name.isEmpty, name != project.title else { reload(); return }
            project.title = name
            if !store.saveProject(project) { reload() }
        default:
            reload()
        }
    }
    @objc private func deleteSelection() {
        guard let selected = contextRoute else { return }
        switch selected { case .project, .area: break; default: return }
        let alert = NSAlert()
        alert.messageText = "删除这个列表？"
        alert.informativeText = "项目会移入废纸篓，其任务随项目隐藏，可从废纸篓恢复。删除区域会保留任务并解除区域关联。也可通过“编辑 → 撤销”恢复。"
        alert.addButton(withTitle: "删除列表"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        switch selected {
        case .project(let id): store.trashProject(id)
        case .area(let id): store.deleteArea(id)
        default: break
        }
        onSelect?(.inbox)
    }
}
