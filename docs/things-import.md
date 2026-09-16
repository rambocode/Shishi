# Things 3 导入

## 使用方式

1. 退出 Things 3，按官方说明用 Finder 复制整个 `.thingsdatabase` 数据库包。
2. 在拾事选择“文件 → 从 Things 3 导入…”，选择包或其中的 `main.sqlite`。
3. 检查预览数量和警告后导入。现有拾事数据会先备份。

导入不需要 Things Cloud 账户，也不向外部服务发送数据。若 macOS 拒绝访问，请选择已导出的可访问副本；应用不会自动搜索其他数据目录或绕过系统权限。

## 字段转换

| Things | 拾事 |
|---|---|
| `TMTask.type=0/1/2` | 任务 / 项目 / 标题分组 |
| `TMArea` | 区域 |
| `TMTag`、`TMTaskTag`、`TMAreaTag` | 全局、任务、项目、区域标签及关联 |
| `TMChecklistItem` | 保留顺序、完成状态、原始 ID 的清单项 |
| `status=0/2/3` | 开放 / 取消 / 完成 |
| `start=0/1/2` | 收件箱 / 随时或已安排 / 某天 |
| `startDate`、`deadline` | 按年月日位编码转换的本地日期，彼此独立 |
| `startBucket` | 今天 / 今晚 |
| `deadlineSuppressionDate` | 原有到期提示隐藏状态 |
| `index`、`todayIndex` | 普通顺序和今天顺序 |
| `trashed` 及祖先项目状态 | 废纸篓与继承的删除状态 |
| `rt1_recurrenceRule` 等 | 支持的简单规则与来源原文；关联既有实例 |

Things 的短字符串 ID 按实体命名空间稳定映射为 UUID。标题相同不会合并，源 ID 相同不会重复创建。

## 事务与重复导入

源连接用 `SQLITE_OPEN_READONLY`，查询在一致性事务中完成；所有结构验证通过后才生成预览。目标库先备份，再原子合并。引用无效、未知状态或不支持版本会整体拒绝，不留下半份导入。

重复导入以源快照更新相同原始 ID；本地独立新增记录保留，本地已删除状态不会被重复导入自动恢复。导入前的备份可以恢复全部旧状态。导出源数据库只读，验证前后对 `main.sqlite` 做哈希比较。

## 已知转换边界

- 空标题记录保留为“未命名…（Things 导入）”，原空值与是否为 NULL 记录在来源元数据。
- 原始提醒时间保留在来源信息，目前不会发出对应系统通知。
- 没有开放实例的旧重复模板保留，不补造历史实例。复杂重复规则无法可靠转换时保留原文并提示，不推测执行频率。
- 项目整体重复、标签父子层级与快捷键等不能视为已完整实现 Things 对等行为。
- 这是一份独立数据副本。之后在 Things 或拾事中的修改不会自动双向同步。

## 来源

- [Things 官方导出说明](https://culturedcode.com/things/support/articles/2982272/)
- [things.py 公开数据库接口源码](https://github.com/thingsapi/things.py)
- 当前本机 Things 3.24 的已授权导出副本 schema；测试仅输出数量和校验结果，不把真实任务内容写进源码。
