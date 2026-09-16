import AppKit

/// 统一隐藏视觉焦点环，不改变first responder、光标、选区或键盘导航。
@MainActor final class FocusAppearance {
    private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let window = note.object as? NSWindow else { return }
                Self.removeRings(in: window.contentView?.superview ?? window.contentView)
                Self.updateResponder(in: window)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                if let window = note.object as? NSWindow { Self.updateResponder(in: window) }
            }
        })
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    static func removeRings(in view: NSView?) {
        guard let view else { return }
        suppress(view)
        view.subviews.forEach { removeRings(in: $0) }
    }
    static func updateResponder(in window: NSWindow) {
        if let view = window.firstResponder as? NSView { suppress(view) }
        // 文本输入使用共享field editor；真正绘制外圈的是它的所属输入控件。
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           let control = editor.delegate as? NSView { suppress(control) }
    }
    private static func suppress(_ view: NSView) {
        if view.focusRingType != .none { view.focusRingType = .none }
        if let cell = (view as? NSControl)?.cell, cell.focusRingType != .none { cell.focusRingType = .none }
    }
}
