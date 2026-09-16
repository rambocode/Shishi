import AppKit

struct ChecklistDragPayload: Codable, Equatable {
    let sourceID: UUID
    let itemID: UUID
    static let pasteboardType = NSPasteboard.PasteboardType("shishi.inline-checklist-row")
    func pasteboardItem() -> NSPasteboardItem? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: Self.pasteboardType)
        return item
    }
    static func read(_ pasteboard: NSPasteboard) -> Self? {
        guard let data = pasteboard.data(forType: pasteboardType) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

@MainActor final class ChecklistDragHandle: NSView, NSDraggingSource {
    let payload: ChecklistDragPayload
    var onSelect: (() -> Void)?
    private var initialEvent: NSEvent?
    init(payload: ChecklistDragPayload) {
        self.payload = payload
        super.init(frame: .zero)
        setAccessibilityLabel("排序检查列表项")
        toolTip = "拖动排序"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setStroke()
        let path = NSBezierPath()
        for offset in [-4.0, 0, 4] {
            path.move(to: NSPoint(x: bounds.midX - 5, y: bounds.midY + offset))
            path.line(to: NSPoint(x: bounds.midX + 5, y: bounds.midY + offset))
        }
        path.lineWidth = 1.2; path.lineCapStyle = .round; path.stroke()
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) { initialEvent = event; onSelect?() }
    override func mouseUp(with event: NSEvent) { initialEvent = nil }
    override func mouseDragged(with event: NSEvent) {
        guard let initialEvent,
              hypot(event.locationInWindow.x - initialEvent.locationInWindow.x,
                    event.locationInWindow.y - initialEvent.locationInWindow.y) >= 3,
              let writer = payload.pasteboardItem() else { return }
        self.initialEvent = nil
        let item = NSDraggingItem(pasteboardWriter: writer)
        let image = NSImage(size: bounds.size)
        image.lockFocus(); draw(bounds); image.unlockFocus()
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }
}

@MainActor final class ChecklistDocument: NSView {
    var onValidateDrop: ((ChecklistDragPayload) -> Bool)?
    var onDrop: ((ChecklistDragPayload, Int) -> Bool)?
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([ChecklistDragPayload.pasteboardType])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var isFlipped: Bool { true }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSource is ChecklistDragHandle,
              sender.draggingSourceOperationMask.contains(.move),
              let payload = ChecklistDragPayload.read(sender.draggingPasteboard),
              onValidateDrop?(payload) == true else { return [] }
        return .move
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { draggingUpdated(sender) == .move }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard draggingUpdated(sender) == .move,
              let payload = ChecklistDragPayload.read(sender.draggingPasteboard) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        let count = Int(bounds.height / 28)
        let index = min(count, max(0, Int((point.y / 28 + 0.5).rounded(.down))))
        return onDrop?(payload, index) == true
    }
}
