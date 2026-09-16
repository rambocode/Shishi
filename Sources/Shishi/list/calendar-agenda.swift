import AppKit
import ShishiCore

@MainActor final class CalendarAgendaView: NSView {
    private let service: SystemIntegrations
    private let scroll = NSScrollView()
    private let document = AgendaDocumentView()
    private let text = NSTextField(wrappingLabelWithString: "")
    private lazy var retry = NSButton(title: "重试", target: self, action: #selector(retryRead))
    private var height: NSLayoutConstraint!
    private var observer: NSObjectProtocol?
    private var work: Task<Void, Never>?
    private var route: Route = .inbox
    private(set) var errorMessage: String?
    convenience init() { self.init(service: .shared) }
    init(service: SystemIntegrations) {
        self.service = service; super.init(frame: .zero)
        scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false; scroll.documentView = document
        text.font = .systemFont(ofSize: 12); text.textColor = .secondaryLabelColor
        text.isSelectable = true; addSubview(scroll); document.addSubview(text); document.addSubview(retry)
        retry.isHidden = true; retry.setAccessibilityLabel("重试读取日历摘要")
        scroll.translatesAutoresizingMaskIntoConstraints = false
        height = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([height, scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor)])
        isHidden = true
        observer = NotificationCenter.default.addObserver(forName: SystemIntegrations.changed, object: service, queue: .main) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.update(route: self.route) }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    deinit { work?.cancel(); if let observer { NotificationCenter.default.removeObserver(observer) } }
    override func layout() {
        super.layout()
        guard !isHidden else { document.frame = .zero; return }
        // A scroll document must retain its full content height, independently of the 120pt viewport.
        // Recompute after width changes so long event titles wrap without clipping or horizontal scrolling.
        let width = max(1, scroll.contentView.bounds.width)
        let textWidth = max(1, width - 16)
        let measured = text.attributedStringValue.boundingRect(with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        let textHeight = ceil(measured) + 4
        text.frame = NSRect(x: 8, y: 6, width: textWidth, height: textHeight)
        retry.frame = NSRect(x: 8, y: text.frame.maxY + 4, width: 64, height: 28)
        let contentHeight = retry.isHidden ? text.frame.maxY + 6 : retry.frame.maxY + 6
        document.frame = NSRect(x: 0, y: 0, width: width, height: contentHeight)
        let visibleHeight = min(120, contentHeight)
        if height.constant != visibleHeight { height.constant = visibleHeight }
    }
    @objc private func retryRead() { update(route: route) }
    private func revealContent() {
        isHidden = false; height.constant = 120; needsLayout = true
        layoutSubtreeIfNeeded()
    }
    func update(route: Route) {
        self.route = route; work?.cancel(); isHidden = true; height.constant = 0; text.stringValue = ""; errorMessage = nil
        retry.isHidden = true; document.frame = .zero
        work = Task { [weak self] in
            guard let self else { return }
            do {
                let events = try await service.events(for: route)
                guard !Task.isCancelled, self.route == route, !events.isEmpty else { return }
                let time = DateFormatter(); time.dateStyle = .short; time.timeStyle = .short
                let day = DateFormatter(); day.dateStyle = .short; day.timeStyle = .none
                text.stringValue = "日历事件（只读）\n" + events.map { event in
                    // All-day end dates are exclusive; display the last included local day.
                    let interval: String
                    if event.allDay {
                        let last = Calendar.current.date(byAdding: .day, value: -1, to: event.end) ?? event.start
                        interval = "全天 " + day.string(from: event.start) + (last > event.start ? " – " + day.string(from: last) : "")
                    } else { interval = time.string(from: event.start) + " – " + time.string(from: event.end) }
                    return interval + "  " + event.title + " · " + event.calendarTitle
                }.joined(separator: "\n")
                revealContent()
            } catch {
                guard !Task.isCancelled, self.route == route else { return }
                // A revoked permission still collapses the optional integration. Actual fetch failures
                // remain visible and retry only the read path; retry never requests authorization.
                guard service.calendarEnabled, service.access(.calendar) == .authorized else { return }
                errorMessage = "日历摘要暂时无法读取。"
                text.stringValue = errorMessage!; retry.isHidden = false; revealContent()
            }
        }
    }
}

private final class AgendaDocumentView: NSView {
    override var isFlipped: Bool { true }
}
