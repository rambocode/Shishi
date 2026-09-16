# UX Brief：交互体验对齐 Things 3

- 模式：`build`（用户授权修改产品代码）
- 日期：2026-09-16
- 产品：拾事 Shishi，纯 AppKit macOS 本地待办应用
- 参照物：本机 Things 3.24（`/Applications/Things3.app`），只读观察，未修改其数据

## 基线证据（evidence_type 见括号）

| 编号 | 观察 | 证据 |
|---|---|---|
| B1 | Things 3「项」菜单含 时间⌘S / 移动⇧⌘M / 标签⇧⌘T / 截止日期⇧⌘D / 完成⌘K / 取消⌥⌘K / 捷径 今天T·今晚E·某天O·清除R / 复制⌘D / 在区域中显示⌘L / 归档⇧⌘Y | source-review（AX 菜单导出 `/tmp/shishi-ux/menu-things3.txt`） |
| B2 | 拾事「项」菜单只有 完成⌘K、归档已完成项（无快捷键）、移到废纸篓⌘⌫ | source-review（AX 菜单导出 `/tmp/shishi-ux/menu-shishi.txt`） |
| B3 | 拾事列表按单键 `E`（今晚）、`O`（某天）无任何反应，任务分组不变 | automated-interaction（`shots/t2-key-e.png`、`t2-key-o.png`） |
| B4 | 拾事 `⇧↓` 不扩展选择，只是把单选移到下一行；列表为单选模型 | automated-interaction（`shots/t3-shiftdown.png`）+ source-review（`allowsMultipleSelection` 从未设置） |
| B5 | 拾事 `⌘/`（隐藏边栏）、`⌘D`（复制）无效 | automated-interaction（`shots/t4-cmdslash.png`、`t4-cmdd.png`） |
| B6 | 拾事 `⏎` 展开内联卡片、`⌫` 移到废纸篓、`↑↓` 选择：与 Things 行为一致 | automated-interaction（`shots/t3-return.png`、`t4-del.png`、`t1-arrowdown.png`） |
| B7 | 底部「时间」弹窗（TaskDatePopover）没有「清除安排」，而卡片内的 CardDatePopover 有；同一语义两套入口不一致 | source-review（`list/task-date-popover.swift` vs `list/card-popovers.swift:45`） |

## 本次范围：3 个核心任务

围绕 Things 3 最高频的「整理」工作流，不做视觉重做、不做标签筛选条、不做 Magic Plus 拖拽定位。

- **TASK-A 批量整理**：一次选中多条待办，一次性安排日期 / 移动到项目 / 完成 / 删除。
- **TASK-B 键盘安排**：手不离键盘完成 安排今天·今晚·某天·清除、设截止日期、移动、打标签、取消、复制。
- **TASK-C 取消与恢复**：批量操作只需一次 ⌘Z 即可整体撤销；Escape 可退出选择态；文本输入时单键捷径不得抢键。

## 假设（待验证）

- A1：用户是 Things 3 老用户，肌肉记忆按 Things 键位；因此键位以 Things 为准而非另创一套。
- A2：demo 数据可代表真实数据结构。真实库（1.4MB、680 条日志簿）未用于破坏性测试。

## 能力与边界

- 可运行、可注入真实鼠标/键盘事件、可截图、可读取 AX 树 → 可做 automated-interaction 与 agent 走查。
- 无真人参与者 → 不产出用户成功率、满意度或完成时长。
- 测试实例：`/tmp/shishi-ux/ShishiQA.app`（独立 bundle id 与进程名）+ `--demo --qa --data-path /tmp/shishi-ux/library.json`，与用户真实库完全隔离。
