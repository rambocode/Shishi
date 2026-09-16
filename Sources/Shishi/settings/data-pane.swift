import AppKit

@MainActor final class DataSettingsPane: NSViewController {
    private let dataURL: URL
    private weak var owner: MainWindowController?
    init(dataURL: URL, owner: MainWindowController) {
        self.dataURL = dataURL; self.owner = owner; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
    override func loadView() {
        view = NSView(); let stack = SettingsLayout.stack(in: view)
        stack.addArrangedSubview(SettingsLayout.label("数据保存在这台 Mac 上", size: 17))
        let path = SettingsLayout.note(dataURL.path); path.isSelectable = true; stack.addArrangedSubview(path)
        stack.addArrangedSubview(SettingsLayout.note("备份包含项目、待办、检查列表与导入来源。恢复备份会先校验内容，并备份当前数据；不会改写 Things 的原数据库。"))
        let export = NSButton(title: "导出备份…", target: owner, action: #selector(MainWindowController.exportData))
        let restore = NSButton(title: "恢复备份…", target: owner, action: #selector(MainWindowController.importData))
        let buttons = NSStackView(views: [export, restore]); buttons.spacing = 12; stack.addArrangedSubview(buttons)
        stack.addArrangedSubview(NSButton(title: "打开数据目录", target: self, action: #selector(reveal)))
        stack.addArrangedSubview(SettingsLayout.separator())
        stack.addArrangedSubview(NSButton(title: "从 Things 3 导入…", target: owner, action: #selector(MainWindowController.importThings)))
        stack.addArrangedSubview(SettingsLayout.note("仅从你选择的 Things 数据库副本读取，先预览再导入；重复导入按来源标识合并。"))
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        stack.addArrangedSubview(SettingsLayout.note("拾事 \(version) · 原生 AppKit · 本机签名版本\n当前无自动更新服务，请通过新版本应用包更新。"))
    }
    @objc private func reveal() { NSWorkspace.shared.activateFileViewerSelecting([dataURL]) }
}

@MainActor final class CloudSettingsPane: NSViewController {
    override func loadView() {
        view = NSView(); let stack = SettingsLayout.stack(in: view)
        let icon = NSImageView(image: NSImage(systemSymbolName: "cloud", accessibilityDescription: "云同步未接入")!)
        icon.contentTintColor = .secondaryLabelColor
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true; icon.heightAnchor.constraint(equalToConstant: 64).isActive = true
        stack.addArrangedSubview(icon); stack.addArrangedSubview(SettingsLayout.label("目前仅在这台 Mac 上保存", size: 19))
        stack.addArrangedSubview(SettingsLayout.note("拾事是独立应用，不能登录或复用 Things Cloud。当前没有配置独立同步服务，因此不会显示虚假的连接开关，也不会收集你的 Things 账号或密码。"))
        stack.addArrangedSubview(SettingsLayout.note("需要转移数据时，可使用“数据与备份”中的导出与恢复。此操作是手动迁移，不是多设备实时同步。"))
    }
}
