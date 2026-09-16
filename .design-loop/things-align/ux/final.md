# 验收记录 · things-align@1

- 模式：`build`
- 契约：things-align / revision 1
- 实现对象：真实运行产品（AppKit 应用），非模拟原型
- 测试实例：`/tmp/shishi-ux/ShishiQA.app` + `--demo --qa --data-path /tmp/shishi-ux/library.json`
- 环境：macOS 27.0（Darwin 27.0.0）、单显示器、键盘 + 鼠标事件经 CGEvent 注入
- 数据版本：内置 demo 快照；用户真实库（`~/Library/Application Support/Shishi/library.json`）全程未被打开或写入
- 轮次：2（第 1 轮发现 1 个 P1、1 个 P2，第 2 轮修复后复验）

## 场景结果

证据类型统一为 `automated-interaction`（Agent 注入真实鼠标/键盘事件 + 截图 + 数据文件断言）。
截图在 `/tmp/shishi-ux/shots/`，数据断言用 `/tmp/shishi-ux/state.py`。

| 场景 | 任务 | 操作路径 | 断言 | 结果 |
|---|---|---|---|---|
| SC-01 | TASK-A | 点首行 → ⇧↓×2 → `E` | 3 条分组从「今天·X」变为「今晚·X」，底部显示「已选 3 项」 | pass |
| SC-02 | TASK-A | 多选 3 条 → ⇧⌘M → 选项目 | 3 条 projectID/areaID 全部改写 | pass（第 2 轮） |
| SC-03 | TASK-A | 多选 3 条 → `⌫` | 3 条 deletedAt 同时写入 | pass |
| SC-04 | TASK-B | 单选 → `E`→`O`，换列表 → `R`，⌘A → `T` | dated+evening → someday → anytime → 9 条全部 dated 今天 | pass |
| SC-05 | TASK-B | 多选 3 条 → ⇧⌘T → 勾选「沟通」→ 完成 | 3 条 tags 同时替换为 ['沟通']；弹窗初值为共同标签（此例为空） | pass |
| SC-06 | TASK-C | SC-02 / SC-03 / 批量完成后各按一次 ⌘Z | 每次一次撤销还原整批 | pass |
| SC-07 | TASK-C | ⌘F 后按 t,o,u,r；⏎ 展开卡片后按 t,e,o,r | 字符完整进入搜索框与卡片标题，任务 schedule 未变 | pass |
| SC-08 | TASK-C | 多选 3 条 → Escape | 选择清空，底部工具栏回到默认态 | pass |
| SC-09 | TASK-B | ⌘/ 两次 | 边栏隐藏后恢复 | pass |
| SC-10 | TASK-A | 项目页展开录入项 → ⌘点选 1 开放 + 1 已完成 → ⌘K | 开放项变 completed；已完成项 completedAt 保持 811094400 未被改写 | pass |

补充验证（契约范围内的其余键位）：⌥⌘K 取消 pass、⌘D 复制 pass、⇧⌘D 批量截止日期 pass（第 2 轮）、
⌘A 全选 pass（9 条待办入选，3 个项目行未被选中）、⌘1/⌘4/⌘5 路由 pass。

## 第 1 轮发现并已修复

**F1（P1，已修复）批量弹窗只作用于一条。**
⇧⌘D 打开批量截止日期弹窗，选日期后只有 1 条被写入。
根因：`applyDeadlineToSelection` / `applyTagsToSelection` / `moveSelection` 在**回调里**才读
`table.selectedRowIndexes`；NSPopover 与 NSMenu 会接管事件循环，其间选择可能被折叠成一行。
修复：所有入口在打开弹窗/菜单的那一刻就把作用对象捕获成 `ids` 快照，闭包只用这份快照
（`list-shortcuts.swift`、`list-selection.swift`）。复验：3 条截止日期全部写入 2026-09-18。

**F2（P2，已修复）底部工具栏菜单弹到窗口外。**
底部工具栏贴着窗口下沿，`popUp(at: y: bounds.height)` 让菜单整块落在窗口下方，盖住其他应用。
这是既有行为，不只影响新增的批量菜单。
修复：新增 `NSMenu.popUpAboveToolbar(from:)`，用最后一项对齐锚点实现向上展开；
底部的移动菜单、更多菜单、清单菜单统一改用它。复验：菜单在窗口内向上弹出。

## 未解决 / 已知限制

- **P3 撤销后不保持多选。** ⌘Z 触发 reload，选择收敛为单行。Things 3 同样不保持，暂不处理。
- **环境冲突（非产品缺陷）：** 本机欧路词典占用 ⇧⌘M 全局快捷键，会先弹出取词窗口。
  验证期间临时退出欧路词典，验证后已重新打开。如需长期共存，需在其中一侧改键。
- **AX 菜单栏路径未纳入验收。** 通过辅助功能 API 点击菜单栏触发批量动作时，选择可能已被系统折叠；
  真实用户的鼠标与快捷键路径不受影响，两条路径都已改为捕获式，但 AX 路径未再复验。
- **无真人研究。** 本轮只有工程与专家走查证据，没有参与者、成功率、满意度或完成时长数据。
  「Things 老用户按同一键位能直接上手」仍是待验证假设（brief 中的 A1）。

## 自动化测试

`swift test`：176 个通过、1 个跳过（需要真实 Things 数据源的用例）、0 失败。
本次新增 10 个：`Tests/ShishiCoreTests/batch-selection-tests.swift`
覆盖 INV-2（一次撤销）、INV-4（跳过不可操作项）、副本不继承来源 ID、
以及 INV-3 的判据 `ItemCommandGate`（文本输入/卡片编辑/sheet/modal/非主窗口时捷径必须禁用）。

## 评审

`self-review`（无独立 reviewer）。G1–G4 四关在上述证据下通过，无遗留 P0/P1。
该结论只覆盖本契约的 3 个任务与列出的分支，不代表整个产品无问题，也不等同真人可用性结论。

退出状态：`accepted`（build 模式，四关通过，约定场景均有运行证据）。
