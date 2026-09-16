import AppKit

/// 平时看起来是普通标题；双击后原地变成输入框。
/// 输入停顿即保存（实时生效），Return 或点别处提交，Escape 还原成编辑前的标题。
@MainActor final class InlineTitleField: NSTextField, NSTextFieldDelegate {
    /// 输入节流间隔，与项目备注保持一致。
    static let saveDelay: TimeInterval = 0.6
    /// 为 false 时双击无效（例如已完成或已删除的项目）。
    var isRenameEnabled = false
    /// 保存标题；返回 false 表示写入失败。空标题不会调用。
    var onSave: ((String) -> Bool)?
    /// 进入与退出编辑时通知宿主，宿主据此暂停会重建视图的刷新。
    var onEditingChanged: ((Bool) -> Void)?
    private(set) var isEditingTitle = false
    private var original = ""
    private var lastSaved = ""
    private var saveTimer: Timer?

    convenience init(title: String) {
        self.init(labelWithString: title)
        lineBreakMode = .byTruncatingTail
    }

    /// 编辑时宽度跟随文字：可滚动单元格默认无固有宽度，会撑满并把旁边的“…”按钮推到最右。
    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        guard isEditingTitle else { return base }
        let text = currentEditor()?.string ?? stringValue
        let width = (text as NSString).size(withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 13)]).width
        return NSSize(width: ceil(width) + 12, height: base.height)
    }

    override func mouseDown(with event: NSEvent) {
        if isRenameEnabled, !isEditingTitle, event.clickCount == 2 { beginEditing(); return }
        super.mouseDown(with: event)
    }

    /// 切换为可编辑并全选；表格行里的标题由表格的双击动作调用。
    func beginEditing() {
        guard isRenameEnabled, !isEditingTitle, let window else { return }
        isEditingTitle = true
        original = stringValue
        lastSaved = stringValue
        isEditable = true
        isSelectable = true
        // 编辑态：浅蓝圆角底、无边框无焦点环，光标用品牌蓝。
        drawsBackground = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = Appearance.selectionBackground.cgColor
        // 标签默认可换行，字段编辑器里 Return 只会换行；单行模式才让 Return 提交。
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        delegate = self
        onEditingChanged?(true)
        window.makeFirstResponder(self)
        if let editor = currentEditor() as? NSTextView {
            // 字段编辑器默认白底，会在浅蓝底上露出一块白色矩形。
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            editor.insertionPointColor = Appearance.blue
        }
        currentEditor()?.selectAll(nil)
        invalidateIntrinsicContentSize()
    }

    /// 导航、关窗前由宿主调用，保证最后一次输入落盘。
    func commitEditing() {
        guard isEditingTitle else { return }
        finish(commit: true)
    }

    func controlTextDidChange(_ obj: Notification) {
        invalidateIntrinsicContentSize()
        saveTimer?.invalidate()
        // RunLoop 定时器在 common 模式下，输入和滚动期间也会按时触发。
        let timer = Timer(timeInterval: Self.saveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveCurrent() }
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard isEditingTitle else { return }
        finish(commit: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // 输入法候选期间的按键交还给输入法。
        guard isEditingTitle, !textView.hasMarkedText() else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finish(commit: false); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { finish(commit: true); return true }
        return false
    }

    /// 实时保存：空白标题跳过，等用户继续输入或放弃。
    private func saveCurrent() {
        saveTimer?.invalidate(); saveTimer = nil
        let text = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isEditingTitle, !text.isEmpty, text != lastSaved else { return }
        if onSave?(text) == true { lastSaved = text }
    }

    /// commit 为 false 时撤回实时保存过的中间结果，回到编辑前的标题。
    private func finish(commit: Bool) {
        saveTimer?.invalidate(); saveTimer = nil
        if commit {
            let text = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { stringValue = lastSaved }
            else if text != lastSaved, onSave?(text) == true { lastSaved = text }
            stringValue = lastSaved
        } else {
            if lastSaved != original, onSave?(original) == true { lastSaved = original }
            stringValue = original
        }
        isEditingTitle = false
        delegate = nil
        isEditable = false
        isSelectable = false
        layer?.backgroundColor = nil
        usesSingleLineMode = false
        cell?.wraps = true
        if let window, currentEditor() != nil { window.makeFirstResponder(nil) }
        invalidateIntrinsicContentSize()
        onEditingChanged?(false)
    }
}
