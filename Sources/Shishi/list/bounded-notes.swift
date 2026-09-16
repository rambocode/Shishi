import AppKit

/// 占位文字叠在文本上方且不接收点击，点击穿透到下面的文本视图开始输入。
/// 不用 NSTextView 子类绘制：子类会改变系统文本排版实现，破坏未分配宽度时的测量行为。
@MainActor private final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 按文档高度收缩、超出上限后滚动的备注，不改变父窗口尺寸。
/// 默认只读；项目页打开 isNotesEditable 后可直接输入，变化通过回调交给宿主保存。
@MainActor final class BoundedNotesView: NSScrollView, NSTextViewDelegate {
    /// expanded 用于共享外层滚动的项目备注：全文高度、无内部滚动条。
    enum DisplayMode { case bounded, expanded }
    var displayMode: DisplayMode = .bounded {
        didSet {
            guard displayMode != oldValue else { return }
            measurementDirty = true
            heightLimit.isActive = displayMode == .bounded
            updateDocument()
        }
    }
    private let textView = NSTextView(frame: .zero)
    /// 占位不进入 string，避免“备注”二字被当成真实备注保存。
    private let placeholderLabel = PassthroughLabel(labelWithString: "")
    private var updating = false
    private var preferredHeight: CGFloat = 18
    private var heightLimit: NSLayoutConstraint!
    private var measurementDirty = true
    private var measuredWidth: CGFloat?
    private var measuredLimit: CGFloat?

    var maximumHeight: CGFloat = 160 {
        didSet { updateDocument() }
    }
    var stringValue: String {
        get { textView.string }
        set {
            guard textView.string != newValue else { return }
            textView.string = newValue
            updatePlaceholder()
            measurementDirty = true
            updateDocument()
        }
    }
    var font: NSFont? {
        get { textView.font }
        set {
            guard textView.font != newValue else { return }
            textView.font = newValue
            placeholderLabel.font = newValue
            updatePlaceholder()
            measurementDirty = true
            updateDocument()
        }
    }
    /// 输入过程中的每次变化；宿主据此节流保存。
    var onTextChange: ((String) -> Void)?
    /// 失去焦点时触发，宿主应立即落盘未保存的内容。
    var onEndEditing: ((String) -> Void)?
    var placeholder: String {
        get { placeholderLabel.stringValue }
        set { placeholderLabel.stringValue = newValue; updatePlaceholder() }
    }
    var isNotesEditable: Bool {
        get { textView.isEditable }
        set { textView.isEditable = newValue }
    }
    /// 正在输入时宿主刷新不能覆盖文字，否则光标和未保存内容会丢失。
    var isEditingNotes: Bool { textView.isEditable && window?.firstResponder === textView }
    var textColor: NSColor? {
        get { textView.textColor }
        set { textView.textColor = newValue }
    }

    override init(frame: NSRect = .zero) {
        super.init(frame: frame)
        borderType = .noBorder
        drawsBackground = false
        hasHorizontalScroller = false
        hasVerticalScroller = false
        autohidesScrollers = false
        scrollerStyle = .legacy
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.delegate = self
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .secondaryLabelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        documentView = textView
        placeholderLabel.textColor = .placeholderTextColor
        placeholderLabel.font = textView.font
        // NSScrollView 自己排布子视图，不跑普通子视图的约束，占位标签改为手动定位。
        addSubview(placeholderLabel)
        updatePlaceholder()
        heightLimit = heightAnchor.constraint(lessThanOrEqualToConstant: 160)
        heightLimit.isActive = true
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        updateDocument()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateDocument()
    }

    override func layout() {
        super.layout()
        updateDocument()
        updatePlaceholder()
    }

    func textDidChange(_ notification: Notification) {
        measurementDirty = true
        updateDocument()
        updatePlaceholder()
        onTextChange?(textView.string)
    }

    private func updatePlaceholder() {
        placeholderLabel.isHidden = placeholderLabel.stringValue.isEmpty || !textView.string.isEmpty
        guard !placeholderLabel.isHidden else { return }
        placeholderLabel.sizeToFit()
        // 滚动视图坐标不翻转，占位贴顶需要从上边缘往下算。
        let y = isFlipped ? 0 : max(0, bounds.height - placeholderLabel.frame.height)
        placeholderLabel.setFrameOrigin(NSPoint(x: 0, y: y))
    }

    func textDidEndEditing(_ notification: Notification) { onEndEditing?(textView.string) }

    override func scrollWheel(with event: NSEvent) {
        if displayMode == .expanded { nextResponder?.scrollWheel(with: event) }
        else { super.scrollWheel(with: event) }
    }

    private func updateDocument() {
        guard !updating, heightLimit != nil else { return }
        updating = true
        defer { updating = false }
        let limit: CGFloat = displayMode == .expanded ? .greatestFiniteMagnitude
            : (maximumHeight.isFinite ? max(1, maximumHeight) : 160)
        if displayMode == .bounded, heightLimit.constant != limit { heightLimit.constant = limit }
        // loadView 尚未分配宽度时不排版；保留待测量状态，首次可视高度仍受上限约束。
        guard bounds.width.isFinite, bounds.width > 1 else {
            applyVisibleHeight(min(preferredHeight, limit))
            return
        }
        // layout 回调和仅高度变化无需重复执行 TextKit 全文排版。
        if !measurementDirty, measuredWidth == bounds.width, measuredLimit == limit {
            applyVisibleHeight(preferredHeight)
            return
        }
        // 先用无滚动条的宽度测量，避免上一轮的滚动条让短文误判为溢出。
        let fullWidth = bounds.width
        var documentHeight = measuredHeight(width: fullWidth)
        let needsScroller = documentHeight > limit
        if hasVerticalScroller != needsScroller { hasVerticalScroller = needsScroller }
        let scrollerWidth = needsScroller
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let documentWidth = max(1, fullWidth - scrollerWidth)
        if needsScroller { documentHeight = measuredHeight(width: documentWidth) }
        let height = min(limit, documentHeight)
        applyVisibleHeight(height)
        let size = NSSize(width: documentWidth, height: documentHeight)
        if textView.frame.size != size { textView.setFrameSize(size) }
        if displayMode == .expanded, contentView.bounds.origin != .zero { contentView.scroll(to: .zero) }
        measuredWidth = fullWidth
        measuredLimit = limit
        measurementDirty = false
        reflectScrolledClipView(contentView)
    }

    private func applyVisibleHeight(_ height: CGFloat) {
        if preferredHeight != height {
            preferredHeight = height
            invalidateIntrinsicContentSize()
        }
        // 手动布局时也严格限高；Auto Layout 则由 intrinsic height 和 required 上限决定。
        if translatesAutoresizingMaskIntoConstraints, frame.height != height {
            super.setFrameSize(NSSize(width: frame.width, height: height))
        }
    }

    private func measuredHeight(width: CGFloat) -> CGFloat {
        guard let container = textView.textContainer, let manager = textView.layoutManager else { return 18 }
        let size = NSSize(width: width, height: .greatestFiniteMagnitude)
        if container.containerSize != size { container.containerSize = size }
        manager.ensureLayout(for: container)
        let lineHeight = manager.defaultLineHeight(for: textView.font ?? .systemFont(ofSize: 14))
        return ceil(max(lineHeight, manager.usedRect(for: container).maxY))
    }
}
