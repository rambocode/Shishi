import AppKit
import ShishiCore

@MainActor
final class ThingsImportCoordinator {
    private let store: TaskStore
    private weak var window: NSWindow?
    private var loading: NSWindow?
    var onFinish: (() -> Void)?
    init(store: TaskStore, window: NSWindow?) { self.store = store; self.window = window }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "从 Things 3 导入"
        panel.message = "先退出 Things，再选择导出的 Things Database.thingsdatabase 数据库包或其中的 main.sqlite。只读导入，原数据保持不变。"
        panel.prompt = "预览导入"
        panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.treatsFilePackagesAsDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        readSource(url)
    }
    private func readSource(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        showProgress()
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try ThingsImporter.read(from: url) } }.value
            if scoped { url.stopAccessingSecurityScopedResource() }
            closeProgress()
            switch result {
            case .success(let value): preview(value)
            case .failure(let error): showError(error)
            }
        }
    }
    private func showProgress() {
        guard let window else { return }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 410, height: 105))
        let label = Appearance.label("正在读取 Things 数据库…", size: 14, weight: .medium)
        label.frame = NSRect(x: 56, y: 47, width: 310, height: 24)
        let progress = NSProgressIndicator(frame: NSRect(x: 23, y: 47, width: 22, height: 22))
        progress.style = .spinning; progress.startAnimation(nil)
        content.addSubview(label); content.addSubview(progress)
        let panel = NSWindow(contentRect: content.bounds, styleMask: [.titled], backing: .buffered, defer: false)
        panel.contentView = content; loading = panel; window.beginSheet(panel)
    }
    private func closeProgress() {
        if let loading { window?.endSheet(loading); loading.orderOut(nil) }
        loading = nil
    }
    private func preview(_ result: ThingsImportResult) {
        let data = result.snapshot
        let alert = NSAlert()
        alert.messageText = "导入 Things 3 数据"
        alert.informativeText = "\(data.todos.count) 条任务 · \(data.projects.count) 个项目 · \(data.areas.count) 个区域\n\(data.projects.reduce(0) { $0 + $1.headings.count }) 个标题分组 · \(data.todos.reduce(0) { $0 + $1.checklist.count }) 条清单项\n\n将先备份拾事当前数据，再合并导入。相同原始标识会更新为 Things 导出内容，保留拾事独立新增记录及废纸篓状态；原 Things 数据库保持不变。"
        if !result.warnings.isEmpty {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 470, height: 150))
            let text = NSTextView(frame: scroll.bounds)
            text.isEditable = false; text.isRichText = false; text.font = .systemFont(ofSize: 12)
            text.string = "导入注意事项\n" + result.warnings.joined(separator: "\n")
            text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
            scroll.documentView = text; scroll.hasVerticalScroller = true; alert.accessoryView = scroll
        }
        alert.addButton(withTitle: "导入"); alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let stats = try store.mergeImported(data)
            let done = NSAlert(); done.messageText = "Things 数据导入完成"
            done.informativeText = "新增 \(stats.added) 个记录，更新 \(stats.updated) 个记录。\n任务、项目和区域已写入拾事的独立数据库。"
            done.runModal(); onFinish?()
        } catch { showError(error) }
    }
    private func showError(_ error: Error) {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "未能导入 Things 数据"
        alert.informativeText = error.localizedDescription + "\n\n请确认选择的是完整数据库导出包，并已退出 Things。拾事现有数据保持原样。"
        alert.runModal()
    }
}
