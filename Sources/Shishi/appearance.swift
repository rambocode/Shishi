import AppKit
import ShishiCore

@MainActor enum Appearance {
    /// 全应用唯一的品牌蓝 #1D60C4；系统蓝明度过高，所有自绘蓝色统一从这里取。
    static let blue = NSColor(srgbRed: 0x1D / 255.0, green: 0x60 / 255.0, blue: 0xC4 / 255.0, alpha: 1)
    /// 选中/编辑中的浅蓝底 #D7E5FF，标题分组与检查项共用；深色模式改用半透明品牌蓝。
    static let selectionBackground = NSColor(name: "SelectionBackground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 0x1D / 255.0, green: 0x60 / 255.0, blue: 0xC4 / 255.0, alpha: 0.35)
            : NSColor(srgbRed: 0xD7 / 255.0, green: 0xE5 / 255.0, blue: 0xFF / 255.0, alpha: 1)
    }
    /// 列表内的细分隔线（标题分组、检查项共用），比系统分隔线更浅。
    static var listSeparator: NSColor { NSColor.separatorColor.withAlphaComponent(0.2) }
    /// 左侧面板背景：浅色 #F9F9FA；深色模式沿用系统窗口底色，避免暗色界面出现亮块。
    static let sidebarBackground = NSColor(name: "SidebarBackground") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.windowBackgroundColor
            : NSColor(srgbRed: 0xF9 / 255.0, green: 0xF9 / 255.0, blue: 0xFA / 255.0, alpha: 1)
    }
    static func apply(_ preferences: GeneralPreferences) {
        guard let app = NSApp else { return }
        let desired: NSAppearance?
        switch preferences.appearance {
        case 1: desired = NSAppearance(named: .aqua)
        case 2: desired = NSAppearance(named: .darkAqua)
        default: desired = nil
        }
        guard app.appearance?.name != desired?.name else { return }
        app.appearance = desired
        // 仅真实主题切换触发自绘视图刷新，数据保存不反复设置主题或重绘全应用。
        func invalidate(_ view: NSView) {
            view.needsDisplay = true
            view.subviews.forEach(invalidate)
        }
        app.windows.compactMap(\.contentView).forEach(invalidate)
    }
    static func label(_ text: String, size: CGFloat = 13, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.lineBreakMode = .byTruncatingTail
        return field
    }
    static func symbol(_ name: String, description: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: description)
    }
    static func title(for route: Route, store: TaskStore) -> String {
        switch route {
        case .inbox: return "收件箱"
        case .today: return "今天"
        case .upcoming: return "计划"
        case .anytime: return "随时"
        case .someday: return "某天"
        case .logbook: return "日志簿"
        case .trash: return "废纸篓"
        case .project(let id): return store.projects.first { $0.id == id }?.title ?? "项目"
        case .area(let id): return store.areas.first { $0.id == id }?.title ?? "区域"
        case .search(let term): return "搜索：\(term)"
        case .tag(let name): return "#\(name)"
        }
    }
}

extension NSView {
    func pinEdges(to parent: NSView, inset: CGFloat = 0) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }
}
