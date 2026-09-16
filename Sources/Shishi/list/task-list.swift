import AppKit
import ShishiCore

@MainActor
final class TaskListController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate {
    let store: TaskStore
    private var currentRoute: Route = .today
    var route: Route {
        get { currentRoute }
        set {
            guard newValue != currentRoute else { return }
            guard finishInlineEditing() else { onRouteChangeBlocked?(currentRoute); return }
            currentRoute = newValue; isProjectHistoryExpanded = false; reload()
            view.layoutSubtreeIfNeeded()
            contentScroll.contentView.scroll(to: .zero)
            contentScroll.reflectScrolledClipView(contentScroll.contentView)
        }
    }
    var onInlineEditingChanged: ((Bool) -> Void)?
    /// 保存失败时主代理可将侧栏选择恢复为实际保留的路由。
    var onRouteChangeBlocked: ((Route) -> Void)?
    var inlineEditor: InlineTaskEditorView?
    var savingInline = false
    private var keyMonitor: Any?
    private var outsideClickMonitor: Any?
    var onEditTask: ((UUID) -> Void)?
    var onNewTask: (() -> Void)?
    var onEditProject: ((UUID) -> Void)?
    var onNavigate: ((Route) -> Void)?
    var onSearch: (() -> Void)?
    var onReminderSaved: (() -> Void)?
    private var taskDatePanel: NSPopover?
    /// 「项」菜单快捷键打开的批量弹窗，与底部按钮弹窗分开管理。
    var shortcutPopover: NSPopover?
    private var taskDateTaskID: UUID?
    let contextualDate = DateToolbarButton(title: "", target: nil, action: nil)
    var selectedTaskID: UUID? { task(at: table.selectedRow)?.id }
    var contextHeadingID: UUID? {
        if let id = headingRows[table.selectedRow] { return id }
        if let editor = inlineEditor { return editor.collect().headingID }
        return selectedTaskID.flatMap(store.todo)?.headingID
    }
    var selectedProjectID: UUID? { project(at: table.selectedRow)?.id }
    var canDeleteSelection: Bool {
        if let editor = inlineEditor { return editor.selectedChecklistItemID != nil }
        if project(at: table.selectedRow) != nil { return true }
        return selectedTaskID != nil
    }
    private enum Row { case heading(String), task(Todo), project(Project), historyToggle(Int) }
    private(set) var isProjectHistoryExpanded = false
    private var rows: [Row] = []
    private var headingRows: [Int: UUID] = [:]
    private var headingPopover: NSPopover?
    /// 重复面板需要强引用，否则弹出后可能随局部变量一起释放。
    var repeatPopover: NSPopover?
    let table = ListTableView()
    private let contentScroll = NSScrollView()
    private var tableHeight: NSLayoutConstraint?
    private var inlineResizePending = false
    /// 项目页标题可双击原地改名；其它列表的标题只读。
    private let heading = InlineTitleField(title: "")
    private let subtitle = BoundedNotesView()
    private let calendarService: SystemIntegrations
    private lazy var calendarAgenda = CalendarAgendaView(service: calendarService)
    private let icon = NSImageView()
    private let projectProgress = ProjectProgressView()
    private let projectMore = CardToolButton(symbol: "ellipsis", title: "项目更多操作")
    private lazy var projectActions = ProjectActionsController(store: store)
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let primary = BottomToolbarButton(title: "＋ 新建任务", target: nil, action: nil)
    private let projectButton = NSButton(title: "编辑项目", target: nil, action: nil)
    private let addHeadingButton = BottomToolbarButton(title: "新建标题", target: nil, action: nil)
    let dateButton = BottomToolbarButton(title: "日期", target: nil, action: nil)
    let moveButton = BottomToolbarButton(title: "移动", target: nil, action: nil)
    private let searchButton = BottomToolbarButton()
    private let defaultTools = NSStackView()
    let contextualTools = NSStackView()
    let contextualMove = NSButton()
    let contextualDelete = NSButton()
    let contextualMore = NSButton()
    private var observer: NSObjectProtocol?
    private var preferencesObserver: NSObjectProtocol?
    private let dragType = NSPasteboard.PasteboardType("app.local.shishi.task")
    private var contentWidth: NSLayoutConstraint?
    private var subtitleLeading: NSLayoutConstraint?
    /// 项目备注输入中尚未落盘的内容与节流任务，见 project-notes.swift。
    var pendingProjectNotes: (id: UUID, text: String)?
    var projectNotesSaveTimer: Timer?
    /// 正在原地改名的标题（项目标题或标题分组）；分组在表格行里，编辑期间刷新会重建行，需要延后。
    var editingTitleField: InlineTitleField?
    var titleReloadPending = false

    init(store: TaskStore, calendarService: SystemIntegrations? = nil) {
        self.store = store
        self.calendarService = calendarService ?? .shared
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
    }

    override func loadView() {
        view = ListBackgroundView()
        let document = ListScrollDocumentView()
        let content = ListScrollDocumentView()
        let toolbar = ListToolbarView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toolbar)
        let scroll = contentScroll
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.addTableColumn(NSTableColumn(identifier: .init("task")))
        table.headerView = nil
        // 行选中背景表达当前位置，不再绘制包围整个列表的系统焦点环。
        table.focusRingType = .none
        table.rowHeight = 28
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.backgroundColor = .textBackgroundColor
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.doubleAction = #selector(edit)
        table.registerForDraggedTypes([dragType])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.editSelection = { [weak self] in self?.edit() }
        table.deleteSelection = { [weak self] in self?.deleteSelected() }
        table.clearSelection = { [weak self] in self?.clearSelection() }
        table.menuForRow = { [weak self] in self?.contextMenu(row: $0) }
        table.beforeMouseDown = { [weak self] row, event in
            guard let self, let editor = self.inlineEditor else { return true }
            if self.task(at: row)?.id == editor.draft.id { return true }
            // 先记住点击对象，收起卡片后行号与坐标会变化，不能再按旧坐标投递。
            let taskID = self.task(at: row)?.id, projectID = self.project(at: row)?.id
            guard self.finishInlineEditing() else { return false }
            if let id = taskID {
                self.selectTask(id)
                if event.clickCount > 1, let task = self.store.todo(id) { self.beginEditing(task, isNew: false); return false }
            } else if let id = projectID { self.navigateProject(id) }
            self.focusList()
            return false
        }
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        scroll.documentView = document
        tableHeight = table.heightAnchor.constraint(equalToConstant: 0)
        tableHeight?.isActive = true
        table.onContentHeightChanged = { [weak self] in
            guard let self else { return }
            let height = self.table.fullContentHeight
            if self.tableHeight?.constant != height { self.tableHeight?.constant = height }
        }
        heading.font = .systemFont(ofSize: 24, weight: .bold)
        heading.lineBreakMode = .byTruncatingTail
        heading.setAccessibilityLabel("项目名称")
        heading.onEditingChanged = { [weak self, weak heading] editing in self?.titleEditingChanged(heading, editing: editing) }
        heading.onSave = { [weak self] title in
            guard let self, case .project(let id) = self.route, var project = self.store.projects.first(where: { $0.id == id }) else { return false }
            project.title = title
            return self.store.saveProject(project)
        }
        subtitle.font = .systemFont(ofSize: CGFloat(store.preferences.textSize))
        subtitle.textColor = .secondaryLabelColor
        subtitle.onTextChange = { [weak self] text in self?.projectNotesChanged(text) }
        subtitle.onEndEditing = { [weak self] _ in self?.flushProjectNotes() }
        count.font = .systemFont(ofSize: 11)
        count.textColor = .tertiaryLabelColor
        empty.font = .systemFont(ofSize: 14)
        empty.textColor = .tertiaryLabelColor
        empty.alignment = .center
        primary.bezelStyle = .inline
        primary.target = self; primary.action = #selector(primaryAction)
        projectButton.bezelStyle = .inline
        projectButton.target = self; projectButton.action = #selector(editProject)
        projectMore.target = self; projectMore.action = #selector(showProjectMenu(_:))
        addHeadingButton.bezelStyle = .inline; addHeadingButton.target = self; addHeadingButton.action = #selector(addHeadingAction(_:))
        addHeadingButton.setAccessibilityLabel("在项目中新建标题分组")
        for button in [dateButton, moveButton] { button.bezelStyle = .inline; button.target = self }
        dateButton.action = #selector(showDates(_:))
        moveButton.action = #selector(showMoves(_:))
        dateButton.image = NSImage(systemSymbolName: "calendar", accessibilityDescription: "安排选中任务")
        moveButton.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: "移动选中任务")
        dateButton.imagePosition = .imageLeading; moveButton.imagePosition = .imageLeading
        let tools = defaultTools
        let mainActions: [(NSButton, String, String)] = [(primary, "plus", "新建待办"), (addHeadingButton, "tag.badge.plus", "新建标题"), (dateButton, "calendar", "时间"), (moveButton, "arrow.right", "移动"), (searchButton, "magnifyingglass", "搜索")]
        for (button, symbol, label) in mainActions {
            button.title = ""; button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.imagePosition = .imageOnly; button.isBordered = false; button.contentTintColor = .secondaryLabelColor; button.toolTip = label
            if button !== addHeadingButton { button.setAccessibilityLabel(label) }
            button.image = button.image?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            button.imageScaling = .scaleNone
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.heightAnchor.constraint(equalToConstant: 36).isActive = true
            tools.addArrangedSubview(button)
        }
        searchButton.target = self; searchButton.action = #selector(searchAction)
        addHeadingButton.hintTitle = "新建标题"; addHeadingButton.hintShortcut = "⇧⌘N"
        addHeadingButton.image = BottomToolbarButton.headingImage()
        addHeadingButton.hintDetail = "将您的项目分为不同类别或阶段"; addHeadingButton.toolTip = nil
        tools.orientation = .horizontal; tools.distribution = .fillEqually; tools.spacing = 8
        tools.detachesHiddenViews = true
        contextualTools.orientation = .horizontal; contextualTools.distribution = .equalSpacing
        let bottomButtons: [(NSButton, String, String, Selector)] = [
            (contextualDate, "calendar", "时间", #selector(showDates(_:))),
            (contextualMove, "arrow.right", "移动", #selector(showContextualMoves(_:))),
            (contextualDelete, "trash", "删除", #selector(deleteFromBottom)),
            (contextualMore, "ellipsis", "更多", #selector(showContextualMore(_:)))
        ]
        for (button, symbol, label, action) in bottomButtons {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.title = ""; button.isBordered = false; button.contentTintColor = .secondaryLabelColor
            button.target = self; button.action = action; button.setAccessibilityLabel(label); button.toolTip = label
            button.widthAnchor.constraint(equalToConstant: 32).isActive = true
            button.heightAnchor.constraint(equalToConstant: 32).isActive = true
            contextualTools.addArrangedSubview(button)
        }
        contextualTools.translatesAutoresizingMaskIntoConstraints = false; toolbar.addSubview(contextualTools)
        let contextWidth = contextualTools.widthAnchor.constraint(equalToConstant: 340); contextWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            contextualTools.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            contextualTools.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor), contextWidth,
            contextualTools.widthAnchor.constraint(lessThanOrEqualTo: toolbar.widthAnchor, constant: -80)
        ])
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        for v in [heading, subtitle, calendarAgenda, icon, projectProgress, projectMore, table, empty] {
            v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v)
        }
        for v in [count, tools] {
            v.translatesAutoresizingMaskIntoConstraints = false; toolbar.addSubview(v)
        }
        let preferredWidth = content.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -124)
        contentWidth = preferredWidth
        subtitleLeading = subtitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 48)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.topAnchor), scroll.bottomAnchor.constraint(equalTo: toolbar.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            document.heightAnchor.constraint(equalTo: content.heightAnchor),
            content.centerXAnchor.constraint(equalTo: document.centerXAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor), toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.bottomAnchor), toolbar.heightAnchor.constraint(equalToConstant: 44),
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 760), preferredWidth,
            content.leadingAnchor.constraint(greaterThanOrEqualTo: document.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -16),
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8), icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
            icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 32),
            heading.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12), heading.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            heading.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -40),
            projectProgress.leadingAnchor.constraint(equalTo: icon.leadingAnchor), projectProgress.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            projectProgress.widthAnchor.constraint(equalToConstant: 28), projectProgress.heightAnchor.constraint(equalToConstant: 28),
            projectMore.leadingAnchor.constraint(equalTo: heading.trailingAnchor, constant: 8), projectMore.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            projectMore.heightAnchor.constraint(equalToConstant: 28), projectMore.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
            subtitleLeading!, subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            subtitle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8),
            // 摘要内部控制0...120点高度；隐藏时两侧间距合计保留原来的28点。
            calendarAgenda.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            calendarAgenda.leadingAnchor.constraint(equalTo: content.leadingAnchor), calendarAgenda.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            table.topAnchor.constraint(equalTo: calendarAgenda.bottomAnchor, constant: 14), table.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            content.bottomAnchor.constraint(greaterThanOrEqualTo: table.bottomAnchor, constant: 8),
            content.bottomAnchor.constraint(greaterThanOrEqualTo: empty.bottomAnchor, constant: 8),
            tools.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor), tools.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            tools.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 16),
            tools.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -16),
            count.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -8), count.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            empty.centerXAnchor.constraint(equalTo: table.centerXAnchor), empty.topAnchor.constraint(equalTo: table.topAnchor, constant: 70),
            empty.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, constant: -24)
        ])
        let documentBottom = content.bottomAnchor.constraint(equalTo: table.bottomAnchor, constant: 8)
        documentBottom.priority = .defaultLow
        documentBottom.isActive = true
        observer = NotificationCenter.default.addObserver(forName: TaskStore.changed, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        preferencesObserver = NotificationCenter.default.addObserver(forName: GeneralPreferences.changed, object: store.preferences, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // 不拆除编辑卡片，不改变草稿、输入法组合文字或焦点；编辑结束已有 reload 会应用最新设置。
                guard let self, self.inlineEditor == nil else { return }
                self.reload()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // 应用内菜单打开时键盘归菜单处理，列表快捷键（如空格新建）不响应。
            guard let self, event.window === self.view.window, InAppMenu.current == nil,
                  event.window?.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            if self.handleSpaceNewTask(event.keyCode, modifiers: event.modifierFlags,
                                       responder: event.window?.firstResponder, isRepeat: event.isARepeat) { return nil }
            let marked = (event.window?.firstResponder as? NSTextView)?.hasMarkedText() ?? false
            return self.handleInlineKey(event.keyCode, modifiers: event.modifierFlags, hasMarkedText: marked) ? nil : event
        }
        outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, let editor = self.inlineEditor, event.window === self.view.window,
                  !editor.bounds.contains(editor.convert(event.locationInWindow, from: nil)) else { return event }
            // 底部检查项操作属于卡片编辑；点击删除后不能收起卡片并把下一击误投给父待办。
            if !self.contextualTools.isHidden, self.contextualTools.bounds.contains(self.contextualTools.convert(event.locationInWindow, from: nil)) { return event }
            // 原点击先完成，随后收起仍打开的同一草稿；不能让行高变化把点击投给另一行。
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self, let editor, self.inlineEditor === editor else { return }
                let active = self.view.window?.firstResponder
                let fieldEditor = active as? NSTextView
                let target: NSResponder? = fieldEditor?.isFieldEditor == true ? (fieldEditor?.delegate as? NSTextField) : active
                let selection = fieldEditor?.selectedRange()
                if self.finishInlineEditing(), let target, target !== self.table {
                    self.view.window?.makeFirstResponder(target)
                    if let field = target as? NSTextField, let selection { field.currentEditor()?.selectedRange = selection }
                }
            }
            return event
        }
        reload()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // 标准宽度下行内容从主区左侧70点开始；窄窗口逐步收紧留白。
        let inset = max(16, min(62, (view.bounds.width - 360) / 2))
        let constant = -2 * inset
        if contentWidth?.constant != constant { contentWidth?.constant = constant }
    }

    func reload() {
        guard isViewLoaded, !savingInline else { return }
        // 表格里的标题分组正在输入时重建行会丢掉输入框，等编辑结束再刷新。
        if let field = editingTitleField, field !== heading { titleReloadPending = true; return }
        let scrollOrigin = contentScroll.contentView.bounds.origin
        subtitle.font = .systemFont(ofSize: CGFloat(store.preferences.textSize))
        let editingDraft = inlineEditor?.collect()
        let activeControl = inlineEditor?.activeControl()
        let selected = selectedTaskID
        let selectedProject = selectedProjectID
        var source = store.items(for: route)
        if let editingDraft, !source.contains(where: { $0.id == editingDraft.id }) { source.insert(editingDraft, at: 0) }
        // 分组只调整展示顺序；同组仍保留 Store 的稳定任务顺序。
        let items: [Todo]
        if route == .today {
            items = source.filter { !$0.evening } + source.filter { $0.evening }
        } else if route == .upcoming {
            items = source.enumerated().sorted {
                let left = planDate($0.element) ?? .distantFuture
                let right = planDate($1.element) ?? .distantFuture
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.element)
        } else if case .project(let id) = route {
            let headings = store.projects.first { $0.id == id }?.headings.filter(HeadingOperations.isVisible).sorted { $0.order < $1.order } ?? []
            items = source.filter { $0.headingID == nil } + headings.flatMap { heading in source.filter { $0.headingID == heading.id } }
                + source.filter { task in task.headingID != nil && !headings.contains { $0.id == task.headingID } }
        } else if route == .logbook || route == .trash {
            items = source
        } else {
            var keys: [String?] = []
            for task in source { let key = groupName(task); if !keys.contains(where: { $0 == key }) { keys.append(key) } }
            items = keys.flatMap { key in source.filter { groupName($0) == key } }
        }
        let projects: [Project]
        if case .project = route { projects = [] }
        else { projects = store.projectItems(for: route) }
        var contentRows = projects.map(Row.project) + items.map(Row.task)
        if route == .today {
            contentRows = contentRows.enumerated().sorted {
                let leftEvening = rowIsEvening($0.element), rightEvening = rowIsEvening($1.element)
                if leftEvening != rightEvening { return !leftEvening }
                let left = rowOrder($0.element), right = rowOrder($1.element)
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.element)
            if store.preferences.groupToday {
                var keys: [String] = []
                for row in contentRows { let key = todayGroupKey(row); if !keys.contains(key) { keys.append(key) } }
                contentRows = keys.flatMap { key in contentRows.filter { todayGroupKey($0) == key } }
            }
        } else if route == .upcoming {
            contentRows = contentRows.enumerated().sorted {
                let left = rowPlanDate($0.element) ?? .distantFuture
                let right = rowPlanDate($1.element) ?? .distantFuture
                return left == right ? $0.offset < $1.offset : left < right
            }.map(\.element)
        }
        rows = []; headingRows = [:]
        var previousGroupKey: String?
        for contentRow in contentRows {
            let group: String?
            if route == .today {
                let period = rowIsEvening(contentRow) ? "今晚" : "今天"
                if store.preferences.groupToday, case .task(let todo) = contentRow, let name = groupName(todo) { group = period + " · " + name }
                else if store.preferences.groupToday, case .project(let p) = contentRow, let name = store.areas.first(where: { $0.id == p.areaID })?.title { group = period + " · " + name }
                else { group = period }
            }
            else if route == .upcoming { group = rowPlanDate(contentRow)?.formatted(.dateTime.year().month().day().weekday(.wide)) ?? "未安排日期" }
            else if case .project = contentRow { group = "项目" }
            else if case .task(let todo) = contentRow { group = groupName(todo) ?? (projects.isEmpty ? nil : "任务") }
            else { group = nil }
            let groupKey = route == .today && store.preferences.groupToday ? todayGroupKey(contentRow) : group
            if let group, groupKey != previousGroupKey { rows.append(.heading(group)) }
            if case .task(let todo) = contentRow, let editingDraft, todo.id == editingDraft.id { rows.append(.task(editingDraft)) }
            else { rows.append(contentRow) }
            previousGroupKey = groupKey
        }
        if case .project(let id) = route, let project = store.projects.first(where: { $0.id == id }) {
            // 标题以ID关联，而非以文字合并；空分组也保留可见的新建入口。
            rows = []; headingRows = [:]
            // 所属标题已存档或不存在的待办（如存档后生成的重复后继、从日志簿恢复的待办）归入无标题区，避免在项目里消失。
            let sections = project.headings.filter(HeadingOperations.isVisible).sorted(by: { $0.order < $1.order })
            let visible = Set(sections.map(\.id))
            let ungrouped = items.filter { $0.headingID.map { !visible.contains($0) } ?? true }
            rows.append(contentsOf: ungrouped.map(Row.task))
            for section in sections {
                headingRows[rows.count] = section.id; rows.append(.heading(section.title))
                rows.append(contentsOf: items.filter { $0.headingID == section.id }.map(Row.task))
            }
        }
        var recorded: [Todo] = []
        if case .project(let id) = route, let project = store.projects.first(where: { $0.id == id }) {
            let summary = ProjectSummary(project: project, tasks: store.todos)
            recorded = summary.recordedItems.filter { $0.pendingArchiveDate == nil }
            projectProgress.configure(project: project, summary: summary)
            if !recorded.isEmpty {
                rows.append(.historyToggle(recorded.count))
                if isProjectHistoryExpanded { rows.append(contentsOf: recorded.map(Row.task)) }
            }
            icon.isHidden = true; projectProgress.isHidden = false; projectMore.isHidden = false
            subtitleLeading?.constant = 8
        } else {
            icon.isHidden = false; projectProgress.isHidden = true; projectMore.isHidden = true
            subtitleLeading?.constant = 48
        }
        let info = headerInfo
        if case .project(let id) = route {
            subtitle.displayMode = .expanded
            // 项目备注在标题下直接编辑；已删除或已关闭的项目只读，与其它编辑入口一致。
            let project = store.projects.first { $0.id == id }
            subtitle.isNotesEditable = project.map { $0.deletedAt == nil && !$0.completed && ($0.status == nil || $0.status == .open) } ?? false
            subtitle.placeholder = subtitle.isNotesEditable ? "备注" : ""
            heading.isRenameEnabled = subtitle.isNotesEditable
        } else {
            subtitle.displayMode = .bounded
            subtitle.isNotesEditable = false
            subtitle.placeholder = ""
            heading.isRenameEnabled = false
        }
        if !heading.isEditingTitle { heading.stringValue = info.0 }
        icon.image = NSImage(systemSymbolName: info.1, accessibilityDescription: info.0)
        icon.contentTintColor = headerColor
        if !subtitle.isEditingNotes { subtitle.stringValue = info.2 }
        calendarAgenda.update(route: route)
        empty.stringValue = route == .trash ? "废纸篓为空\n删除的任务会显示在这里" : "暂无任务\n留一点空间，开始新的计划"
        empty.isHidden = !items.isEmpty || !projects.isEmpty || inlineEditor != nil || !headingRows.isEmpty || !recorded.isEmpty
        count.stringValue = "\(items.count) 个任务" + (projects.isEmpty ? "" : " · \(projects.count) 个项目")
        primary.setAccessibilityLabel(route == .trash || route == .logbook ? "恢复" : "新建待办")
        table.reloadData()
        if let selected { selectTask(selected, reveal: false) }
        if let selectedProject { selectProject(selectedProject, reveal: false) }
        view.layoutSubtreeIfNeeded()
        let maximumY = max(0, (contentScroll.documentView?.bounds.height ?? 0) - contentScroll.contentView.bounds.height)
        contentScroll.contentView.scroll(to: NSPoint(x: scrollOrigin.x, y: min(maximumY, max(0, scrollOrigin.y))))
        contentScroll.reflectScrolledClipView(contentScroll.contentView)
        if let activeControl { view.window?.makeFirstResponder(activeControl) }
        updateTools()
    }

    func selectTask(_ id: UUID, reveal: Bool = true) {
        _ = view
        guard let index = rows.firstIndex(where: { if case .task(let todo) = $0 { return todo.id == id }; return false }) else {
            table.deselectAll(nil); updateTools(); return
        }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        if reveal { table.scrollRowToVisible(index) }
        updateTools()
    }
    func toggleProjectHistory() {
        guard case .project = route, finishInlineEditing() else { return }
        isProjectHistoryExpanded.toggle(); reload()
    }
    @objc private func showProjectMenu(_ sender: NSButton) {
        guard case .project(let id) = route, finishInlineEditing() else { return }
        projectActions.onNavigate = { [weak self] destination in self?.onNavigate?(destination) }
        projectActions.show(projectID: id, from: sender)
    }
    @objc private func searchAction() { onSearch?() }
    func task(at index: Int) -> Todo? {
        guard rows.indices.contains(index), case .task(let todo) = rows[index] else { return nil }; return todo
    }
    func project(at index: Int) -> Project? {
        guard rows.indices.contains(index), case .project(let project) = rows[index] else { return nil }
        return project
    }
    func selectProject(_ id: UUID, reveal: Bool = true) {
        guard let index = rows.firstIndex(where: { if case .project(let project) = $0 { return project.id == id }; return false }) else {
            table.deselectAll(nil); updateTools(); return
        }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        if reveal { table.scrollRowToVisible(index) }; updateTools()
    }
    func focusList() { view.window?.makeFirstResponder(table) }
    /// 与原生事件监听共用的键盘入口；组合输入先由输入法处理。
    @discardableResult func handleInlineKey(_ code: UInt16, modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool) -> Bool {
        guard inlineEditor != nil, !hasMarkedText else { return false }
        if code == 53 { cancelInlineEditing(); return true }
        if (code == 36 || code == 76), modifiers.contains(.command) { saveInlineEditing(); return true }
        return false
    }
    /// 列表浏览状态的裸空格复用新建入口：选中标题则建在该标题下，未选择则不关联标题。
    /// 不抢文本输入、按钮激活或组合快捷键；废纸篓、日志簿、搜索和已关闭项目不响应。
    @discardableResult
    func handleSpaceNewTask(_ code: UInt16, modifiers: NSEvent.ModifierFlags,
                            responder: NSResponder?, isRepeat: Bool = false) -> Bool {
        guard code == 49, !isRepeat,
              modifiers.intersection([.command, .control, .option, .shift]).isEmpty,
              inlineEditor == nil, acceptsSpaceNewTask,
              let create = onNewTask else { return false }
        if let text = responder as? NSTextView, text.isEditable || text.hasMarkedText() { return false }
        if let text = responder as? NSText, text.isEditable { return false }
        if let control = responder as? NSControl, !(control is NSTableView) { return false }
        create()
        return true
    }
    /// 当前路由能否用空格新建：只读列表与搜索结果没有明确的新建归属，项目需仍处于开放状态。
    private var acceptsSpaceNewTask: Bool {
        switch route {
        case .trash, .logbook, .search: return false
        case .project(let id):
            guard let project = store.projects.first(where: { $0.id == id }) else { return false }
            return project.deletedAt == nil && !project.completed && (project.status == nil || project.status == .open)
        default: return true
        }
    }

    func resizeInlineEditor() {
        guard let editor = inlineEditor, let index = rows.firstIndex(where: { if case .task(let task) = $0 { return task.id == editor.draft.id }; return false }) else { return }
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integer: index))
        // TextKit/清单的布局回调内不递归驱动父布局。合并同轮变更，保留当前输入焦点，
        // 在全文高度生效后露出正在编辑的控件（尤其是新增长清单项）。
        guard !inlineResizePending else { return }
        inlineResizePending = true
        DispatchQueue.main.async { [weak self, weak editor] in
            guard let self else { return }
            self.inlineResizePending = false
            guard let editor, self.inlineEditor === editor else { return }
            self.view.layoutSubtreeIfNeeded()
            if let control = editor.activeControl() { control.scrollToVisible(control.bounds) }
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableViewSelectionDidChange(_ notification: Notification) { updateTools() }
    func updateTools() {
        if let panel = taskDatePanel, panel.isShown, taskDateTaskID != selectedTaskID { panel.performClose(nil) }
        // 选择集合变化会让批量弹窗的作用对象失效，先收起再让用户重新发起。
        if let panel = shortcutPopover, panel.isShown, actionableTaskIDs.isEmpty { panel.performClose(nil) }
        let todo = selectedTaskID.flatMap { store.todo($0) }
        let multi = selectedTaskIDs.count
        let editable = (multi > 1 ? !actionableTaskIDs.isEmpty
                        : todo.map { $0.status == .open && Domain.deletionDate($0, in: store.snapshot) == nil } == true) && inlineEditor == nil
        let projectRoute: Bool = { if case .project = route { return true }; return false }()
        dateButton.isEnabled = editable; contextualDate.isEnabled = editable
        moveButton.isEnabled = editable || projectRoute
        if route == .trash || route == .logbook { primary.isEnabled = (todo != nil || selectedProjectID != nil) && inlineEditor == nil }
        else { primary.isEnabled = true }
        projectButton.isHidden = { if case .project = route { return false }; return selectedProjectID == nil }()
        projectButton.isEnabled = inlineEditor == nil
        addHeadingButton.isHidden = { if case .project = route { return false }; return true }()
        let showingActions = inlineEditor != nil || selectedTaskID != nil || selectedProjectID != nil
        defaultTools.isHidden = showingActions; contextualTools.isHidden = !showingActions
        // 多选是不可见的状态，必须在标题旁明确回报选中了几条，否则批量操作无从确认范围。
        count.stringValue = multi > 1 ? "已选 \(multi) 项" : ""
        count.isHidden = multi <= 1
        contextualDelete.isEnabled = canDeleteSelection
        let selectedCheck = inlineEditor?.selectedChecklistItemID != nil
        contextualDelete.setAccessibilityLabel(selectedCheck ? "删除选中的检查项" : inlineEditor != nil ? "请选择要删除的检查项" : "删除选中的事项")
        contextualDelete.toolTip = selectedCheck ? "仅删除选中的检查项，保留父待办" : "删除选中的事项"
        contextualMove.isEnabled = selectedCheck || (inlineEditor == nil && selectedTaskID != nil)
        contextualMore.isEnabled = showingActions
        contextualDelete.setAccessibilityLabel(multi > 1 ? "删除选中的 \(multi) 个事项" : contextualDelete.accessibilityLabel() ?? "删除选中的事项")
    }
    @objc private func deleteFromBottom() { deleteSelected() }
    @objc private func showContextualMoves(_ sender: NSButton) {
        if inlineEditor != nil { showChecklistMenu(from: sender); return }
        if hasMultipleSelection { selectionMoveMenu(for: actionableTaskIDs).popUpAboveToolbar(from: sender); return }
        guard let id = selectedTaskID else { return }
        moveMenu(id).popUpAboveToolbar(from: sender)
    }
    @objc private func showContextualMore(_ sender: NSButton) {
        if inlineEditor != nil { showChecklistMenu(from: sender); return }
        contextMenu(row: table.selectedRow)?.popUpAboveToolbar(from: sender)
    }
    private func showChecklistMenu(from sender: NSButton) {
        guard let editor = inlineEditor else { return }
        let menu = NSMenu(); menu.autoenablesItems = false
        for (title, selector, enabled) in [
            ("上移检查项", #selector(moveChecklistUp), editor.canMoveSelectedChecklistItem(by: -1)),
            ("下移检查项", #selector(moveChecklistDown), editor.canMoveSelectedChecklistItem(by: 1)),
            ("添加检查项", #selector(addChecklistFromBottom), true)
        ] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            item.target = self; item.isEnabled = enabled; menu.addItem(item)
        }
        menu.popUpAboveToolbar(from: sender)
    }
    @objc private func moveChecklistUp() { inlineEditor?.moveSelectedChecklistItem(by: -1); updateTools() }
    @objc private func moveChecklistDown() { inlineEditor?.moveSelectedChecklistItem(by: 1); updateTools() }
    @objc private func addChecklistFromBottom() { inlineEditor?.addChecklist(); updateTools() }
    @objc private func showDates(_ sender: NSButton) {
        // 多选走批量弹窗；单选保留含提醒设置的完整弹窗。
        if hasMultipleSelection { showScheduleForSelection(); return }
        guard let id = selectedTaskID else { return }
        showTaskDatePopover(for: id, from: sender)
    }
    func showTaskDatePopover(for id: UUID, from sender: NSView) {
        guard inlineEditor == nil, let original = store.todo(id),
              original.status == .open, Domain.deletionDate(original, in: store.snapshot) == nil else { return }
        let content = TaskDatePopover(todo: original)
        let panel = NSPopover(); panel.behavior = .transient; panel.animates = false
        panel.delegate = self
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentViewController = content
        // 锚点可能是按钮，也可能是菜单触发时的任意视图；只有按钮才有按下状态需要复位。
        let button = sender as? NSButton
        content.onApply = { [weak self, weak panel] updated in
            guard let self, self.selectedTaskID == id, self.store.todo(id) == original else { return false }
            guard self.store.save(updated) else { return false }
            panel?.performClose(nil)
            button?.state = .off
            return true
        }
        content.onCancel = { [weak panel] in panel?.performClose(nil); button?.state = .off }
        content.onReminderCommit = { [weak self] in self?.onReminderSaved?() }
        taskDatePanel?.performClose(nil); taskDatePanel = panel; taskDateTaskID = id
        button?.state = .on
        panel.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }
    func popoverDidClose(_ notification: Notification) {
        if notification.object as? NSPopover === taskDatePanel {
            contextualDate.state = .off; dateButton.state = .off
        }
    }
    @objc private func showMoves(_ sender: NSButton) {
        if selectedTaskID == nil, case .project(let id) = route { projectActions.showMove(projectID: id, from: sender); return }
        if hasMultipleSelection { selectionMoveMenu(for: actionableTaskIDs).popUpAboveToolbar(from: sender); return }
        guard let id = selectedTaskID else { return }
        moveMenu(id).popUpAboveToolbar(from: sender)
    }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { task(at: row) != nil || project(at: row) != nil || headingRows[row] != nil }
    /// 多选只对待办成立：⇧ 范围选择跨分组时不把分组标题和项目行一起高亮，
    /// 否则用户会以为分组也在批量操作范围内。单选语义保持不变。
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        guard proposedSelectionIndexes.count > 1 else { return proposedSelectionIndexes }
        let tasksOnly = proposedSelectionIndexes.filter { task(at: $0) != nil }
        return tasksOnly.isEmpty ? proposedSelectionIndexes : IndexSet(tasksOnly)
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rowView = TaskListRowView()
        rowView.isHeadingRow = headingRows[row] != nil
        if let editor = inlineEditor, task(at: row)?.id == editor.draft.id { rowView.isEmphasized = false; rowView.isEditingCard = true }
        return rowView
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .historyToggle = rows[row] { return 68 }
        if let editor = inlineEditor, task(at: row)?.id == editor.draft.id { return editor.rowHeight }
        return task(at: row) == nil && project(at: row) == nil ? 38 : max(28, CGFloat(store.preferences.textSize) + 14)
    }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch rows[row] {
        case .historyToggle(let count):
            return ProjectHistoryRowView(count: count, expanded: isProjectHistoryExpanded, textSize: store.preferences.textSize) { [weak self] in self?.toggleProjectHistory() }
        case .heading(let text):
            if let id = headingRows[row] {
                let view = ListHeadingView(text, textSize: store.preferences.textSize, onMore: { [weak self] sender in self?.showHeadingMenu(id, from: sender) },
                                           onTitleSave: { [weak self] title in
                    guard let self, case .project(let projectID) = self.route else { return false }
                    return self.store.renameHeading(id, title: title, in: projectID)
                })
                view.titleField.onEditingChanged = { [weak self, weak view] editing in self?.titleEditingChanged(view?.titleField, editing: editing) }
                return view
            }
            let cell = ListHeadingView(text, textSize: store.preferences.textSize)
            return cell
        case .project(let project):
            let cell = GeneralProjectRowView(project, tasks: store.todos.filter { $0.projectID == project.id }, textSize: store.preferences.textSize)
            return cell
        case .task(let todo):
            if let editor = inlineEditor, editor.draft.id == todo.id { return editor }
            let cell = TaskRowView()
            cell.configure(todo, textSize: store.preferences.textSize) { [weak self] in
                guard let self, self.finishInlineEditing() else { return }
                self.store.toggle(todo.id)
            }
            return cell
        }
    }
    private func todayGroupKey(_ row: Row) -> String {
        let period = rowIsEvening(row) ? "evening" : "day"
        switch row {
        case .task(let t): return period + (t.projectID?.uuidString ?? t.areaID?.uuidString ?? "loose")
        case .project(let p): return period + (p.areaID?.uuidString ?? "loose")
        default: return period
        }
    }
    @objc func edit() {
        // 双击标题分组行：原地改名，不再需要点“…”打开弹窗。
        if table.clickedRow >= 0, headingRows[table.clickedRow] != nil,
           let view = table.view(atColumn: 0, row: table.clickedRow, makeIfNecessary: false) as? ListHeadingView {
            guard finishInlineEditing() else { return }
            view.titleField.beginEditing()
            return
        }
        if let editor = inlineEditor, selectedTaskID == editor.draft.id { return }
        if let id = selectedProjectID { navigateProject(id) }
        else if let id = selectedTaskID, let todo = store.todo(id) { beginEditing(todo, isNew: false) }
    }
    @objc private func clicked() { if let id = selectedProjectID { navigateProject(id) } }
    func navigateProject(_ id: UUID) {
        guard finishInlineEditing() else { onRouteChangeBlocked?(route); return }
        onNavigate?(.project(id))
    }
    @objc private func primaryAction() {
        if route == .trash || route == .logbook {
            // 多选恢复同样合并成一次事务，否则批量恢复后要按很多次撤销。
            let ids = selectedTaskIDs
            if ids.count > 1 { store.restoreMany(ids); restoreSelection(ids); return }
            if let id = selectedProjectID { restoreArchivedProject(id) }
            else if let id = selectedTaskID { restoreTask(id) }
        }
        else if case .project = route, let id = contextHeadingID { newTask(inHeading: id) }
        else { onNewTask?() }
    }
    @objc private func addHeadingAction(_ sender: NSButton) { showHeadingEditor(nil, from: sender) }
    func newHeading() { guard case .project = route else { return }; showHeadingEditor(nil, from: addHeadingButton) }
    func showHeadingEditor(_ id: UUID?, from sender: NSView) {
        guard case .project(let projectID) = route, finishInlineEditing() else { return }
        let controller = ProjectHeadingController(store: store, projectID: projectID, headingID: id)
        let panel = NSPopover(); panel.behavior = .transient; panel.contentViewController = controller
        controller.onFinish = { [weak self, weak panel] _ in panel?.performClose(nil); self?.reload() }
        let anchor = sender.window == nil ? addHeadingButton : sender
        headingPopover = panel; panel.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }
    func newTask(inHeading headingID: UUID) {
        guard case .project(let projectID) = route,
              let project = store.projects.first(where: { $0.id == projectID }),
              project.headings.contains(where: { $0.id == headingID && HeadingOperations.isVisible($0) }) else { return }
        let todo = Todo(title: "", schedule: .anytime, projectID: projectID, areaID: project.areaID, headingID: headingID)
        beginEditing(todo, isNew: true)
    }
    @objc private func editProject() {
        if let id = selectedProjectID { onEditProject?(id) }
        else if case .project(let id) = route { onEditProject?(id) }
    }
    func deleteSelected() {
        if let editor = inlineEditor {
            if editor.selectedChecklistItemID != nil { editor.removeSelectedChecklistItem(); updateTools() }
            return
        }
        // 多选优先按批量处理；项目行仍走原有单条确认流程，避免混合删除语义。
        let ids = selectedTaskIDs
        if ids.count > 1 {
            if route == .trash { confirmPermanentDeletion(ids) } else { store.trashMany(ids) }
            return
        }
        if let id = selectedProjectID {
            if route == .trash || project(at: table.selectedRow)?.deletedAt != nil { confirmProjectDeletion(id) }
            else { store.trashProject(id) }
            return
        }
        guard let id = selectedTaskID else { return }
        if route == .trash { confirmDeletion(id) } else { store.trash(id) }
    }
    private var headerInfo: (String, String, String) {
        switch route {
        case .inbox: return ("收件箱", "tray", "收集想法，稍后安排")
        case .today: return ("今天", "star.fill", Date().formatted(.dateTime.month().day().weekday(.wide)))
        case .upcoming: return ("计划", "calendar", "未来的任务与截止日期")
        case .anytime: return ("随时", "square.stack", "准备好时就开始")
        case .someday: return ("某天", "archivebox", "留给未来的想法")
        case .logbook: return ("日志簿", "checkmark.square", "已完成和已取消的任务")
        case .trash: return ("废纸篓", "trash", "恢复任务，或永久删除")
        case .project(let id): let p = store.projects.first { $0.id == id }; return (p?.title ?? "项目", "circle.dotted", p?.notes ?? "")
        case .area(let id): return (store.areas.first { $0.id == id }?.title ?? "区域", "square.grid.2x2", "这个领域中的所有任务")
        case .search(let query): return ("搜索", "magnifyingglass", "“\(query)”的搜索结果")
        case .tag(let tag): return (tag, "tag", "带有此标签的任务")
        }
    }
    private var headerColor: NSColor {
        switch route {
        case .today: return .systemYellow
        case .upcoming: return .systemPink
        case .anytime: return .systemTeal
        case .someday: return .systemOrange
        case .logbook: return .systemGreen
        case .trash, .search: return .secondaryLabelColor
        case .area: return .systemPurple
        case .inbox, .project, .tag: return Appearance.blue
        }
    }
    private func groupName(_ todo: Todo) -> String? {
        if route == .logbook { return (todo.completedAt ?? todo.createdAt).formatted(.dateTime.year().month().day()) }
        if route == .trash { return todo.deletedAt?.formatted(.dateTime.year().month().day()) }
        if route == .upcoming {
            return planDate(todo)?.formatted(.dateTime.year().month().day().weekday(.wide)) ?? "未安排日期"
        }
        if let projectID = todo.projectID, let project = store.projects.first(where: { $0.id == projectID }) {
            if case .project = route {
                return project.headings.first { $0.id == todo.headingID }?.title ?? "任务"
            }
            return project.title
        }
        if route == .today, let areaID = todo.areaID { return store.areas.first { $0.id == areaID }?.title }
        return nil
    }
    private func planDate(_ todo: Todo) -> Date? {
        let day = Calendar.current.startOfDay(for: Date())
        return [todo.startDate, todo.deadline].compactMap { $0 }.map { Calendar.current.startOfDay(for: $0) }.filter { $0 > day }.min()
    }
    private func rowIsEvening(_ row: Row) -> Bool {
        if case .task(let task) = row { return task.evening }
        if case .project(let project) = row { return project.evening == true }
        return false
    }
    private func rowOrder(_ row: Row) -> Double {
        switch row {
        case .task(let task): return task.source?.metadata["todayIndex"].flatMap(Double.init) ?? task.order
        case .project(let project): return project.source?.metadata["todayIndex"].flatMap(Double.init) ?? project.order
        case .heading, .historyToggle: return 0
        }
    }
    private func rowPlanDate(_ row: Row) -> Date? {
        if case .task(let task) = row { return planDate(task) }
        if case .project(let project) = row {
            let day = Calendar.current.startOfDay(for: Date())
            return [project.startDate, project.deadline].compactMap { $0 }.map { Calendar.current.startOfDay(for: $0) }.filter { $0 > day }.min()
        }
        return nil
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard inlineEditor == nil else { return nil }
        let id: UUID
        if let todo = task(at: row), todo.deletedAt == nil, todo.status == .open { id = todo.id }
        else if route == .today, let project = project(at: row), project.deletedAt == nil,
                !project.completed, project.status == nil || project.status == .open { id = project.id }
        else { return nil }
        let item = NSPasteboardItem(); item.setString(id.uuidString, forType: dragType); return item
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard inlineEditor == nil, route != .trash, route != .logbook,
              let value = info.draggingPasteboard.string(forType: dragType), let id = UUID(uuidString: value) else { return [] }
        if store.todo(id) == nil {
            guard route == .today, (info.draggingSource as? NSTableView) === table,
                  rows.contains(where: { if case .project(let project) = $0 { return project.id == id }; return false }) else { return [] }
        }
        tableView.setDropRow(row, dropOperation: .above); return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard let value = info.draggingPasteboard.string(forType: dragType), let id = UUID(uuidString: value) else { return false }
        return acceptDraggedItem(id, at: row, fromLocalList: (info.draggingSource as? NSTableView) === table)
    }
    func acceptDraggedItem(_ id: UUID, at row: Int, fromLocalList: Bool) -> Bool {
        guard inlineEditor == nil, route != .trash, route != .logbook else { return false }
        if let historyIndex = rows.firstIndex(where: { if case .historyToggle = $0 { return true }; return false }), row > historyIndex { return false }
        let dropRow = max(0, min(row, rows.count))
        if route == .today {
            // 必须在Store通知刷新前固定混合顺序，分组标题不占排序位置。
            let visibleIDs = rows.compactMap(rowID)
            let insertion = rows.prefix(dropRow).compactMap(rowID).filter { $0 != id }.count
            let nextRow = rows.dropFirst(dropRow).first { rowID($0) != id }
            let targetRow = nextRow ?? rows.last { rowID($0) != nil && rowID($0) != id }
            let targetEvening: Bool
            if let targetRow, case .heading(let title) = targetRow { targetEvening = title == "今晚" }
            else if let targetRow { targetEvening = rowIsEvening(targetRow) }
            else { targetEvening = false }
            var ids = visibleIDs.filter { $0 != id }
            if let task = store.todo(id) {
                guard task.status == .open, task.deletedAt == nil else { return false }
                if !visibleIDs.contains(id) {
                    store.move(id, to: .today)
                    guard store.items(for: .today).contains(where: { $0.id == id }) else { return false }
                }
                if var moved = store.todo(id), moved.evening != targetEvening {
                    moved.evening = targetEvening
                    guard store.save(moved) else { return false }
                }
            } else {
                guard fromLocalList, visibleIDs.contains(id),
                      let project = store.snapshot.projects.first(where: { $0.id == id }),
                      !project.completed, project.deletedAt == nil, project.status == nil || project.status == .open else { return false }
            }
            ids.insert(id, at: min(insertion, ids.count))
            store.reorderToday(ids)
            guard store.errorMessage == nil else { return false }
            if store.todo(id) != nil { selectTask(id) } else { selectProject(id) }
            return true
        }
        // 普通reorder只接受任务ID，项目不能跨路由混入。
        guard let original = store.todo(id), original.status == .open, original.deletedAt == nil else { return false }
        let destinationTask = rows.dropFirst(dropRow).compactMap { if case .task(let t) = $0, t.id != id, t.status == .open { return t }; return nil }.first
        let destination = destinationTask?.id
        let groupTarget = destinationTask ?? rows.reversed().compactMap { if case .task(let t) = $0, t.id != id, t.status == .open { return t }; return nil }.first
        // 跨列表拖入先按当前路由移动，再以可见任务的顺序排序。
        if !rows.contains(where: { if case .task(let t) = $0 { return t.id == id }; return false }) {
            store.move(id, to: route)
            guard store.items(for: route).contains(where: { $0.id == id }) else { return false }
        }
        if var moved = store.todo(id), let groupTarget {
            if case .project = route { moved.headingID = groupTarget.headingID }
            if route == .today { moved.evening = groupTarget.evening }
            guard store.save(moved) else { return false }
        }
        var ids = rows.compactMap { if case .task(let t) = $0, t.status == .open { return t.id }; return nil }.filter { $0 != id }
        if let destination, let index = ids.firstIndex(of: destination) { ids.insert(id, at: index) } else { ids.append(id) }
        store.reorder(ids); selectTask(id); return true
    }
    private func rowID(_ row: Row) -> UUID? {
        switch row {
        case .task(let task): return task.id
        case .project(let project): return project.id
        case .heading, .historyToggle: return nil
        }
    }
}
