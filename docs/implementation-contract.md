# 拾事 / Shishi 实现合同 v1

用户要求完全参照 Things 3 的 macOS app，纯 AppKit，不得使用 SwiftUI。独立名称“拾事”，独立 bundle ID app.local.shishi，独立数据库。用户后续明确允许直接导入 Things3 数据：仅只读处理通过正规导出/文件选择获得的授权数据库副本，导入独立数据库；禁止写入Things原库。只参照已观察的布局与功能，示例数据须合成。不得使用 Things 图标/品牌资源。

## 协作
所有 worker gpt-5.6-sol / medium。共享绝对项目路径 /Users/mike/Documents/Codex/2026-09-15/x/outputs/Shishi。保留其他代理与用户改动；各自仅修改合同规定文件。不得 git commit/push、安装依赖或操控 Things/UI；主代理负责构建集成、应用运行与验收。SwiftPM 无外部依赖，Swift tools 5.9 / macOS 13。文件短小 lower-kebab-case，中文必要注释。

## 冻结公共类型
ShishiCore/models.swift 已提供 Todo, Project, Area, Heading, ChecklistItem, RepeatRule, Snapshot, Route。不能自行改变已有字段，可沟通扩展。

## Store 合同（数据代理实现 Sources/Shishi/store.swift）
@MainActor final class TaskStore
- init(fileURL: URL, demo: Bool = false) 不 throws，加载失败设置 errorMessage 并禁止覆盖坏文件；新库默认空库，demo 显式填充合成示例。
- private(set) var snapshot: Snapshot；var errorMessage: String?
- var todos: [Todo], projects: [Project], areas: [Area], allTags: [String] 只读。
- static let changed = Notification.Name("ShishiStoreChanged")；成功修改发送 NotificationCenter.default object:self。
- func items(for route: Route, now: Date = Date()) -> [Todo]
- func todo(_ id: UUID) -> Todo?
- @discardableResult func save(_ todo: Todo) -> Bool 验证去空白标题、引用合法性，原子保存成功才更新内存/通知；失败保留旧状态。
- func toggle(_ id: UUID), cancel(_ id: UUID), trash(_ id: UUID), restore(_ id: UUID), permanentlyDelete(_ id: UUID)
- @discardableResult func saveProject(_ project: Project) -> Bool; saveArea(_ area: Area) -> Bool
- func deleteProject(_ id: UUID), deleteArea(_ id: UUID) 将关联开放任务合理解关联不丢数据
- func move(_ id: UUID, to route: Route), reorder(_ ids: [UUID])
- func undo(), redo(); var canUndo: Bool, canRedo: Bool
- func exportData(to: URL) throws; func importData(from: URL) throws（验证版本、唯一 ID、引用、备份后替换，事务性）
- ShishiCore 领域和持久化无 AppKit。Store 只协调主线程和通知。核心单元测试实现数据代理所有权。

## 列表合同（列表代理实现 Sources/Shishi/list/）
final class TaskListController: NSViewController
- init(store: TaskStore)
- var route: Route = .today { didSet reload }
- var onEditTask: ((UUID) -> Void)?; onNewTask: (() -> Void)?; onEditProject: ((UUID) -> Void)?
- var selectedTaskID: UUID? { get }
- func reload(), selectTask(_ id: UUID)
- header 中文路由名称、语义 SF Symbol、日期/项目说明；NSTableView 自绘精致任务行，完成复选框，备注/标签/清单/截止徽标，今天/今晚/项目标题分组，计划按天分组，空状态，logbook 和 trash 恢复/删除。
- 双击及 Return 行内编辑，新建也在列表内出现草稿；有效草稿切换前保存失败阻止切换并保留输入；Escape明确取消，CmdReturn保存。完整详情使用现有controller。右键完成/取消/安排今天/今晚/明天/某天/移动项目/删除/恢复；拖拽排序/移动。所有入口要真实生效。可调用 store，不修改 store。
- Things 风格白纸主区、居中内容最大宽约760、36高任务行、蓝色细分隔标题、底部轻量工具条。NSColor 动态语义色，系统字体 14，主标题28，不卡死窄窗口。主代理负责外层侧栏与window。

## 编辑合同（编辑代理实现 Sources/Shishi/editor/）
final class TaskEditorController: NSViewController
- init(store: TaskStore, todo: Todo, isNew: Bool)
- var onFinish: ((UUID?) -> Void)? 保存成功 id、取消 nil；由主代理关闭 sheet。
- 标题、备注、逐条可勾选/添加/移除清单、逗号标签、归属项目/区域、标题分组、开始日期与独立截止日期、今天/今晚/明天/随时/某天快捷安排、日历 NSDatePicker、重复频率和完成后间隔。
- 不在取消时写入，保存失败显示 store.errorMessage，空标题不能保存；键盘 Cmd+Return 保存 Escape取消。完整可访问标签。
final class ProjectEditorController: NSViewController
- init(store: TaskStore, project: Project); var onFinish: ((UUID?) -> Void)?
- 编辑名称、说明、区域、截止、完成状态、项目内标题分组。
final class AreaEditorController: NSViewController
- init(store: TaskStore, area: Area); var onFinish: ((UUID?) -> Void)?
- 编辑名称。

## 主代理所有权
Package.swift, models.swift, app.swift, window.swift, sidebar/, appearance.swift, settings/, scripts/, docs/, README.md, .design-loop/。负责通知错误呈现、菜单与快捷键、搜索、导入导出、侧栏项目/区域管理、打包、真实截图和最终验收。不提前改 workers 所有权文件。

## 产品边界
验收本机离线应用的实际行为。不擅自实现/宣称 Things Cloud、跨设备客户端、邮件服务或 Apple 专有系统服务已对等；缺失处必须记录为未完成而非声称完整复制。启动空数据，--demo 用独立示例库；--data-path 支持隔离验收数据。
