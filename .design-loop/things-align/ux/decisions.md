# 决策记录 · things-align@1

## 已读取契约
已读取契约：things-align / revision 1
本次涉及：TASK-A / TASK-B / TASK-C，states 全部，transitions T1–T8
保持不变：INV-1 纯 AppKit、INV-2 一次撤销、INV-3 捷径让位文本、INV-4 跳过不可操作项、INV-5 失败不改状态、INV-6 不碰真实库

## 关键取舍

**D1 单键捷径用 NSMenuItem + validateMenuItem，而不是全局按键监听。**
Things 3 也把 T/E/O/R 放在「项 → 捷径」菜单里。走菜单的好处是：
可发现（菜单里能看见）、可被系统统一显示、并且在 `validateMenuItem` 返回 false 时
AppKit 不吞事件，字符自动回到输入框。自建 `NSEvent` 监听则要自己复刻这套让位规则，容易漏。
判据抽成 `ItemCommandGate`（window.swift），可在无 keyWindow 的测试环境直接断言。

**D2 批量操作放在 TaskStore 而不是循环调用单条 API。**
原有 `save/toggle/trash` 每次都 `commit` 一次，循环会产生 N 个撤销步，
用户按一次 ⌘Z 只能退回一条。新增 `moveMany/scheduleMany/completeMany/cancelMany/
trashMany/reopenMany/restoreMany/duplicateMany/saveMany/permanentlyDeleteMany`，
每个只 `commit` 一次。`move` 改为 `moveMany([id])` 的特例，归属规则抽到 `applyMove` 共用，
避免单条与批量语义漂移。

**D3 单选保留原有 TaskDatePopover，多选才用 CardDatePopover。**
拾事的 `TaskDatePopover` 比 Things 的日期弹窗多了中文日期输入和提醒设置，
而提醒是逐条语义，批量设同一个提醒会产生一批重复通知。
所以 ⌘S 在单选时打开原弹窗（能力不降级），多选时打开批量弹窗（无提醒）。

**D4 给 TaskDatePopover 补「清除安排」。**
基线 B7：同一语义在卡片弹窗有、在底部弹窗没有。补齐后两处一致，
且与捷径 R 指向同一结果（回到「随时」），与 Things 的「清除」同义。

**D5 多选时范围选择过滤掉分组标题与项目行。**
`selectionIndexesForProposedSelection` 在提议选择超过一行时只保留待办行。
Things 3 的分组标题不可选；拾事的标题行承担「新建到此分组」的职责必须保留单选，
因此只在多选时过滤，不改单选语义。

**D6 右键命中已选行时保留整个多选。**
原 `ListTableView.menu(for:)` 无条件把选择重置为单行，会让批量菜单悄悄缩成单条。
改为只有命中未选中的行才重置。

## 范围外（已记录未做）
- Things 的「在区域中显示 ⌘L」。
- 多选行一次拖拽到侧栏。
- 今天页的标签筛选条（Things 有，拾事无）。
- 富文本备注标记快捷键（⌘B/⌘I 等）。
