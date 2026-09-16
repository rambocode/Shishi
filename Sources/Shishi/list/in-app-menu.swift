import AppKit

/// 应用内菜单的一项：普通动作或分隔线。
enum InAppMenuEntry {
    case item(title: String, icon: String?, enabled: Bool = true, action: () -> Void)
    case separator
}

/// 深色圆角的应用内菜单。系统 NSMenu 跟随系统外观且可以伸出窗口，
/// 这里改用挂在主窗口上的子窗口：外观固定为深色，位置始终夹在主窗口内容区内。
@MainActor
final class InAppMenu: NSObject {
    /// 当前打开的菜单；打开期间由这里强持有，关闭时释放。同一时间只保留一个，打开新菜单会先关闭旧菜单。
    private(set) static var current: InAppMenu?

    let entries: [InAppMenuEntry]
    var onClose: (() -> Void)?
    private var panel: NSPanel?
    private var menuView: InAppMenuView?
    private weak var parent: NSWindow?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []

    init(entries: [InAppMenuEntry]) { self.entries = entries; super.init() }

    var isOpen: Bool { panel != nil }

    /// 可点选项的标题，按显示顺序，供测试与辅助功能使用。
    var titles: [String] {
        entries.compactMap { if case .item(let title, _, _, _) = $0 { return title }; return nil }
    }

    /// 在锚点下方弹出，右边缘与锚点对齐；下方放不下时翻到锚点上方，并始终夹在窗口内容区内。
    func show(from anchor: NSView) {
        guard let window = anchor.window else { return }
        Self.current?.close()
        let view = InAppMenuView(entries: entries) { [weak self] index in self?.perform(at: index) }
        let size = view.fittingSize
        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let frame = Self.frame(size: size, anchor: anchorRect, container: window.convertToScreen(window.contentLayoutRect))
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = view
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel; menuView = view; parent = window
        Self.current = self
        installMonitors(for: window)
    }

    /// 计算菜单在屏幕坐标中的位置：优先锚点下方右对齐，越界时翻转并夹紧到容器内 8 点边距。
    static func frame(size: NSSize, anchor: NSRect, container: NSRect, gap: CGFloat = 4, margin: CGFloat = 8) -> NSRect {
        var x = anchor.maxX - size.width
        var y = anchor.minY - gap - size.height
        if y < container.minY + margin { y = anchor.maxY + gap }
        x = min(max(x, container.minX + margin), container.maxX - margin - size.width)
        y = min(max(y, container.minY + margin), container.maxY - margin - size.height)
        return NSRect(origin: NSPoint(x: x, y: y), size: size)
    }

    func close() {
        guard let panel else { return }
        monitors.forEach(NSEvent.removeMonitor); monitors = []
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        self.panel = nil; menuView = nil
        if Self.current === self { Self.current = nil }
        onClose?()
    }

    /// 先关闭再执行动作，动作里可以安全地打开下一级菜单或确认框。
    func perform(at index: Int) {
        guard entries.indices.contains(index), case .item(_, _, let enabled, let action) = entries[index], enabled else { return }
        close()
        action()
    }

    /// 按标题执行，供测试模拟点选。
    func perform(title: String) {
        guard let index = entries.firstIndex(where: { if case .item(let value, _, _, _) = $0 { return value == title }; return false }) else { return }
        perform(at: index)
    }

    /// 菜单打开期间接管键盘：Esc 关闭、上下键移动高亮、回车执行；其余按键吞掉，避免触发列表快捷键。
    /// 点击菜单外、滚动、窗口缩放或失去焦点都会关闭菜单，防止菜单与锚点错位。
    private func installMonitors(for window: NSWindow) {
        if let keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard let self, self.isOpen else { return event }
            switch event.keyCode {
            case 53: self.close()
            case 125: self.menuView?.moveHighlight(1)
            case 126: self.menuView?.moveHighlight(-1)
            case 36, 76: if let index = self.menuView?.highlighted { self.perform(at: index) }
            default: break
            }
            return nil
        }) { monitors.append(keys) }
        if let clicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel], handler: { [weak self] event in
            guard let self, self.isOpen, event.window !== self.panel else { return event }
            self.close()
            // 点击菜单外只用于关闭菜单，不穿透到下面的行，与系统菜单一致；滚动照常生效。
            return event.type == .scrollWheel ? event : nil
        }) { monitors.append(clicks) }
        for name in [NSWindow.didResizeNotification, NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.close() }
            })
        }
    }
}

/// 菜单内容：深灰圆角底、浅描边、白字、蓝色图标；悬停或键盘高亮时整行变为品牌蓝。
@MainActor
final class InAppMenuView: NSView {
    private static let background = NSColor(srgbRed: 0x3F / 255.0, green: 0x40 / 255.0, blue: 0x43 / 255.0, alpha: 0.98)
    private static let border = NSColor(white: 1, alpha: 0.16)
    /// 深色底上品牌蓝 #1D60C4 对比度不足，图标改用同色相的亮蓝。
    private static let iconBlue = NSColor(srgbRed: 0x4F / 255.0, green: 0x8E / 255.0, blue: 0xF7 / 255.0, alpha: 1)
    private static let rowHeight: CGFloat = 28, separatorHeight: CGFloat = 11, padding: CGFloat = 6

    private let entries: [InAppMenuEntry]
    private let onSelect: (Int) -> Void
    private var rows: [(index: Int, view: InAppMenuRow)] = []
    private(set) var highlighted: Int? { didSet { rows.forEach { $0.view.isHighlighted = $0.index == highlighted } } }

    init(entries: [InAppMenuEntry], onSelect: @escaping (Int) -> Void) {
        self.entries = entries; self.onSelect = onSelect
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = Self.background.cgColor
        layer?.borderColor = Self.border.cgColor
        layer?.borderWidth = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.menu)
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: Self.padding, left: Self.padding, bottom: Self.padding, right: Self.padding)
        for (index, entry) in entries.enumerated() {
            switch entry {
            case .separator:
                let line = SeparatorLine()
                stack.addArrangedSubview(line)
                line.heightAnchor.constraint(equalToConstant: Self.separatorHeight).isActive = true
                line.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.padding).isActive = true
            case .item(let title, let icon, let enabled, _):
                let row = InAppMenuRow(title: title, icon: icon, enabled: enabled, iconColor: Self.iconBlue)
                row.onHover = { [weak self] inside in if inside && enabled { self?.highlighted = index } else if self?.highlighted == index { self?.highlighted = nil } }
                row.onClick = { [weak self] in if enabled { self?.onSelect(index) } }
                stack.addArrangedSubview(row)
                row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
                row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.padding).isActive = true
                rows.append((index, row))
            }
        }
        addSubview(stack)
        stack.pinEdges(to: self)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// 键盘移动高亮，跳过分隔线与禁用项，首尾循环。
    func moveHighlight(_ step: Int) {
        let enabled = rows.filter { $0.view.isEnabled }.map(\.index)
        guard !enabled.isEmpty else { return }
        guard let current = highlighted, let position = enabled.firstIndex(of: current) else {
            highlighted = step > 0 ? enabled.first : enabled.last; return
        }
        highlighted = enabled[(position + step + enabled.count) % enabled.count]
    }

    /// 两侧留白的细分隔线。
    private final class SeparatorLine: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor(white: 1, alpha: 0.18).setFill()
            NSRect(x: 8, y: bounds.midY - 0.5, width: bounds.width - 16, height: 1).fill()
        }
    }
}

/// 菜单中的一行：图标 + 标题，自行处理悬停与点击。
@MainActor
final class InAppMenuRow: NSView {
    var onHover: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    let isEnabled: Bool
    var isHighlighted = false { didSet { if isHighlighted != oldValue { updateColors() } } }
    private let iconView = NSImageView()
    private let label: NSTextField
    private let iconColor: NSColor

    init(title: String, icon: String?, enabled: Bool, iconColor: NSColor) {
        isEnabled = enabled
        self.iconColor = iconColor
        label = NSTextField(labelWithString: title)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 14)
        iconView.image = icon.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        for child in [iconView, label] as [NSView] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        iconView.isHidden = icon == nil
        setAccessibilityElement(true)
        setAccessibilityRole(.menuItem)
        setAccessibilityLabel(title)
        setAccessibilityEnabled(enabled)
        updateColors()
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // 子窗口不会成为 key 窗口，悬停跟踪必须 activeAlways。
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }

    private func updateColors() {
        layer?.backgroundColor = isHighlighted ? Appearance.blue.cgColor : NSColor.clear.cgColor
        label.textColor = isEnabled ? .white : NSColor(white: 1, alpha: 0.35)
        iconView.contentTintColor = isHighlighted ? .white : (isEnabled ? iconColor : NSColor(white: 1, alpha: 0.35))
    }
}
