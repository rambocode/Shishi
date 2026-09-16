import Foundation

public struct ThingsImportResult {
    public let snapshot: Snapshot
    public let warnings: [String]
    public let sourceCounts: [String: Int]
    public init(snapshot: Snapshot, warnings: [String], sourceCounts: [String: Int]) {
        self.snapshot = snapshot; self.warnings = warnings; self.sourceCounts = sourceCounts
    }
}

public enum ThingsImporter {
    /// 只读取指定 main.sqlite 或 .thingsdatabase/main.sqlite，不自动查找用户数据库。
    /// 读取期间持有一致事务；schema、状态或引用无法验证时整体失败，不返回部分结果。
    public static func read(from url: URL) throws -> ThingsImportResult {
        var directory: ObjCBool = false
        guard url.isFileURL, FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { throw DataError.invalid("Things 导入文件不存在或不可访问") }
        let fileURL: URL
        if directory.boolValue {
            guard url.pathExtension.lowercased() == "thingsdatabase" else { throw DataError.invalid("请选择 .thingsdatabase 包或 SQLite 文件") }
            fileURL = url.appendingPathComponent("main.sqlite")
        } else { fileURL = url }
        let reader = try SQLiteReader(url: fileURL)
        _ = try reader.query("BEGIN DEFERRED TRANSACTION")
        defer { _ = try? reader.query("ROLLBACK") }
        let result = try assemble(reader)
        _ = try reader.query("COMMIT")
        return result
    }

    private static func assemble(_ reader: SQLiteReader) throws -> ThingsImportResult {
        var warnings: [String] = []
        let tasks = try reader.table("TMTask", required: ["uuid", "title", "type", "status", "start"], recommended: ["notes", "startDate", "deadline", "trashed", "project", "area", "creationDate", "startBucket"], warnings: &warnings)
        let areaRows = try reader.table("TMArea", required: ["uuid", "title"], optional: ["table"], warnings: &warnings)
        let tagRows = try reader.table("TMTag", required: ["uuid", "title"], optional: ["table"], warnings: &warnings)
        let links = try reader.table("TMTaskTag", required: [], alternatives: [["tasks", "task"], ["tags", "tag"]], optional: ["table"], warnings: &warnings)
        let areaLinks = try reader.table("TMAreaTag", required: [], alternatives: [["areas", "area"], ["tags", "tag"]], optional: ["table"], warnings: &warnings)
        let checklistRows = try reader.table("TMChecklistItem", required: ["uuid", "title", "status"], alternatives: [["task", "tasks"]], optional: ["table"], warnings: &warnings)
        func indexed(_ rows: [SQLiteRow]) throws -> [String: SQLiteRow] {
            var result: [String: SQLiteRow] = [:]
            for row in rows {
                let id = try row.requiredText("uuid")
                guard result.updateValue(row, forKey: id) == nil else { throw DataError.invalid("Things 数据表包含重复源 ID") }
            }
            return result
        }
        let taskMap = try indexed(tasks), areaMap = try indexed(areaRows), tagMap = try indexed(tagRows)
        _ = try indexed(checklistRows)
        var areas: [Area] = []
        for row in areaRows {
            let source = try row.requiredText("uuid")
            areas.append(Area(id: ThingsID.make(source, kind: "area"), title: try ThingsValues.title(row, kind: "区域", warnings: &warnings), order: try row.number("index", "order") ?? 0, source: try ThingsValues.source(row, id: source)))
        }
        var areaTags: [String: [String]] = [:]
        for row in areaLinks {
            let area = try row.requiredText("areas", "area"), tag = try row.requiredText("tags", "tag")
            guard areaMap[area] != nil, tagMap[tag] != nil else { throw DataError.invalid("Things 区域标签关联引用无效") }
            areaTags[area, default: []].append(tag)
        }
        for index in areas.indices {
            let source = areas[index].source!.identifier
            if let tags = areaTags[source], !tags.isEmpty {
                areas[index].source?.metadata["tagIDs"] = tags.sorted().joined(separator: ",")
                areas[index].tags = try tags.map { try ThingsValues.title(tagMap[$0]!, kind: "标签", warnings: &warnings) }.sorted()
            }
        }
        // Snapshot 没有独立标签实体：完整 registry 保留未使用标签与层级，不只保留已关联名称。
        let registry = try tagRows.map { row -> [String: Any] in
            let id = try row.requiredText("uuid")
            let parent = try row.text("parent")
            if let parent, tagMap[parent] == nil { throw DataError.invalid("Things 标签父级引用不存在") }
            var originalTitle: Any = NSNull()
            if case .text(let text)? = row["title"] { originalTitle = text }
            return ["uuid": id, "title": originalTitle, "parent": parent as Any? ?? NSNull(), "index": try row.number("index") ?? 0]
        }.sorted { ($0["uuid"] as! String) < ($1["uuid"] as! String) }
        let registryData = try JSONSerialization.data(withJSONObject: registry, options: [.sortedKeys])
        let registryJSON = String(decoding: registryData, as: UTF8.self)
        if !areas.isEmpty { areas[0].source?.metadata["tagRegistryJSON"] = registryJSON }
        let parentCount = try tagRows.filter { try $0.text("parent") != nil }.count
        if parentCount > 0 { warnings.append("\(parentCount) 个标签父级关系已保留在来源信息；当前标签筛选采用平铺名称。") }
        let reminders = try tasks.filter { try $0.integer("reminderTime") != nil }.count
        if reminders > 0 { warnings.append("\(reminders) 项提醒时间已保留在来源信息；当前不会发送对应系统提醒。") }
        func areaID(_ source: String?) throws -> UUID? {
            guard let source else { return nil }
            guard areaMap[source] != nil else { throw DataError.invalid("Things 区域引用不存在") }
            return ThingsID.make(source, kind: "area")
        }
        func taskID(_ source: String, type: Int64) throws -> UUID {
            guard let row = taskMap[source], try row.integer("type") == type else { throw DataError.invalid("Things 项目或分组引用无效") }
            return ThingsID.make(source, kind: "task")
        }
        var projects: [Project] = []
        var headingsByProject: [String: [Heading]] = [:]
        var headingProject: [String: String] = [:]
        var repeatRules: [String: RepeatRule] = [:]
        var sourceInfo: [String: SourceInfo] = [:]
        var taskNotes: [String: String] = [:]
        for row in tasks {
            let source = try row.requiredText("uuid")
            var notes = try row.text("notes") ?? ""
            let (info, rule) = try ThingsRepeat.read(row, source: source, notes: &notes, warnings: &warnings)
            sourceInfo[source] = info; repeatRules[source] = rule; taskNotes[source] = notes
        }
        for info in sourceInfo.values {
            if let template = info.metadata["repeatingTemplateID"], sourceInfo[template]?.metadata["repeatTemplate"] != "true" { throw DataError.invalid("Things 重复模板引用不存在或无规则") }
        }
        for row in tasks {
            guard let type = try row.integer("type"), (0...2).contains(type) else { throw DataError.invalid("无法识别 Things 任务类型") }
            if type == 2 {
                let source = try row.requiredText("uuid")
                let parent = try row.requiredText("project")
                _ = try taskID(parent, type: 1)
                headingProject[source] = parent
                let status = try ThingsValues.status(row.integer("status"))
                let stop = try ThingsValues.timestamp(row.number("stopDate"))
                let created = try ThingsValues.timestamp(row.number("creationDate")) ?? Date(timeIntervalSince1970: 0)
                headingsByProject[parent, default: []].append(Heading(id: ThingsID.make(source, kind: "task"), title: try ThingsValues.title(row, kind: "分组", warnings: &warnings), order: try row.number("index", "order") ?? 0, deletedAt: try row.flag("trashed") ? stop ?? created : nil, status: status, notes: taskNotes[source], source: sourceInfo[source]))
                if try row.flag("trashed") { warnings.append("一项已删除分组保留了结构，其子任务将进入回收站。") }
            }
        }
        for row in tasks where try row.integer("type") == 1 {
            let source = try row.requiredText("uuid")
            var notes = taskNotes[source] ?? ""
            let status = try ThingsValues.status(row.integer("status"))
            let trashed = try row.flag("trashed")
            if trashed { notes += "\n\n[Things 导入：原项目位于回收站]"; warnings.append("一项废纸篓项目已完整保留删除标记、状态和子任务。") }
            let start = try ThingsValues.date(row.integer("startDate"))
            let deletion = try ThingsValues.timestamp(row.number("trashDate", "stopDate", "creationDate")) ?? Date(timeIntervalSince1970: 0)
            projects.append(Project(id: ThingsID.make(source, kind: "task"), title: try ThingsValues.title(row, kind: "项目", warnings: &warnings), notes: notes, areaID: try areaID(row.text("area", "areaID")), deadline: try ThingsValues.date(row.integer("deadline")), completed: status != .open, headings: (headingsByProject[source] ?? []).sorted { $0.order < $1.order }, order: try row.number("index", "order") ?? 0, deletedAt: trashed ? deletion : nil, status: status, startDate: start, schedule: try ThingsValues.schedule(row.integer("start"), date: start), source: sourceInfo[source]))
            if repeatRules[source] != nil { warnings.append("一项项目重复规则已保留在来源信息，当前不自动复制整个项目。") }
        }
        var tagsByTask: [String: [String]] = [:]
        var tagIDsByTask: [String: [String]] = [:]
        for row in links {
            let task = try row.requiredText("tasks", "task"), tag = try row.requiredText("tags", "tag")
            guard taskMap[task] != nil, let tagRow = tagMap[tag] else { throw DataError.invalid("Things 标签关联引用无效") }
            tagsByTask[task, default: []].append(try ThingsValues.title(tagRow, kind: "标签", warnings: &warnings))
            tagIDsByTask[task, default: []].append(tag)
        }
        var checklistByTask: [String: [(Double, ChecklistItem)]] = [:]
        for row in checklistRows {
            let source = try row.requiredText("uuid"), task = try row.requiredText("task", "tasks")
            _ = try taskID(task, type: 0)
            let status = try ThingsValues.status(row.integer("status"))
            if status == .canceled { warnings.append("一项取消清单项按已勾选导入。") }
            checklistByTask[task, default: []].append((try row.number("index", "order") ?? 0, ChecklistItem(id: ThingsID.make(source, kind: "checklist"), title: try ThingsValues.title(row, kind: "清单项", warnings: &warnings), completed: status != .open, source: try ThingsValues.source(row, id: source))))
        }
        var todos: [Todo] = []
        let projectMap = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        for row in tasks where try row.integer("type") == 0 {
            let source = try row.requiredText("uuid")
            var heading = try row.text("heading", "actionGroup", "headingID")
            var parent = try row.text("project", "projectID")
            if let reference = parent, try taskMap[reference]?.integer("type") == 2 {
                if let heading, heading != reference { throw DataError.invalid("Things 任务含冲突分组引用") }
                heading = reference; parent = nil
            }
            if let heading {
                _ = try taskID(heading, type: 2)
                guard let owner = headingProject[heading], parent == nil || parent == owner else { throw DataError.invalid("Things 分组与项目归属冲突") }
                parent = owner
            }
            let projectID = try parent.map { try taskID($0, type: 1) }
            let directArea = try areaID(row.text("area", "areaID"))
            let project = projectID.flatMap { projectMap[$0] }
            if projectID != nil, directArea != nil, directArea != project?.areaID { warnings.append("一项任务的旧区域引用与项目不同，已采用项目区域。") }
            var startDate = try ThingsValues.date(row.integer("startDate"))
            if startDate == nil, sourceInfo[source]?.metadata["repeatTemplate"] == "true" {
                // 模板的 nextInstanceStartDate 是计划中下一实例日期，不补造新记录。
                startDate = try ThingsValues.date(row.integer("rt1_nextInstanceStartDate", "nextInstanceStartDate"))
                sourceInfo[source]?.metadata["originalStartDateWasNull"] = "true"
            }
            let status = try ThingsValues.status(row.integer("status"))
            let created = try ThingsValues.timestamp(row.number("creationDate", "createdAt")) ?? Date(timeIntervalSince1970: 0)
            let stop = try ThingsValues.timestamp(row.number("stopDate", "completedAt"))
            let trashed = try row.flag("trashed")
            let deletion = try ThingsValues.timestamp(row.number("trashDate", "deletedAt"))
            let notes = taskNotes[source] ?? ""
            var evening = try row.flag("evening", "isEvening")
            if let bucket = try row.integer("startBucket") {
                guard bucket == 0 || bucket == 1 else { throw DataError.invalid("无法识别 Things 今天/今晚分组") }
                evening = bucket == 1
            }
            if evening && startDate == nil { warnings.append("一项没有开始日期的今晚标记无法应用，已保留其他安排。") }
            var info = sourceInfo[source]
            let tagIDs = tagIDsByTask[source] ?? []
            if !tagIDs.isEmpty { info?.metadata["tagIDs"] = Array(Set(tagIDs)).sorted().joined(separator: ",") }
            let todo = Todo(id: ThingsID.make(source, kind: "task"), title: try ThingsValues.title(row, kind: "任务", warnings: &warnings), notes: notes, status: status, schedule: try ThingsValues.schedule(row.integer("start"), date: startDate), startDate: startDate, deadline: try ThingsValues.date(row.integer("deadline")), evening: evening, projectID: projectID, areaID: projectID == nil ? directArea : project?.areaID, headingID: heading.map { ThingsID.make($0, kind: "task") }, tags: (tagsByTask[source] ?? []).sorted(), checklist: (checklistByTask[source] ?? []).sorted { $0.0 == $1.0 ? $0.1.id.uuidString < $1.1.id.uuidString : $0.0 < $1.0 }.map(\.1), repeatRule: repeatRules[source], createdAt: created, completedAt: status == .open ? nil : stop, deletedAt: trashed ? deletion ?? stop ?? created : nil, order: try row.number("index", "order") ?? 0, source: info, deadlineSuppressionDate: try ThingsValues.date(row.integer("deadlineSuppressionDate")))
            todos.append(Domain.normalized(todo))
        }
        if areas.isEmpty, !todos.isEmpty { todos[0].source?.metadata["tagRegistryJSON"] = registryJSON }
        if areas.isEmpty && todos.isEmpty && !registry.isEmpty { warnings.append("源库只有独立标签，当前 Snapshot 无法保存独立标签实体，未自动创建虚构任务。") }
        // 旧库的固定重复模板不是普通待办；把规则连接到唯一最新开放实例，避免重造已有实例。
        for (templateID, rule) in repeatRules {
            let candidates = todos.indices.filter { todos[$0].source?.metadata["repeatingTemplateID"] == templateID && todos[$0].status == .open && todos[$0].deletedAt == nil }
            if let index = candidates.max(by: { todos[$0].createdAt < todos[$1].createdAt }) {
                todos[index].repeatRule = rule
                for (key, value) in sourceInfo[templateID]?.metadata ?? [:] where key != "repeatTemplate" { todos[index].source?.metadata[key] = value }
                if candidates.count > 1 { warnings.append("一项重复模板有多个开放实例，仅最新实例继续生成周期。") }
            } else { warnings.append("一项重复模板没有开放实例，模板及原规则已保留；未自动补造历史周期。") }
        }
        // 项目标签结构化保存，供筛选继承，不混入用户原始备注。
        for index in projects.indices {
            if let source = projects[index].source?.identifier, let tags = tagsByTask[source], !tags.isEmpty {
                projects[index].tags = Array(Set(tags)).sorted()
            }
        }
        let globalTags = try tagRows.map { try ThingsValues.title($0, kind: "标签", warnings: &warnings) }
        let snapshot = Snapshot(todos: todos.sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }, projects: projects.sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }, areas: areas.sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }, tags: Array(Set(globalTags)).sorted())
        try Domain.validate(snapshot)
        let grouped = Dictionary(grouping: warnings, by: { $0 }).map { message, values in values.count > 1 ? "\(message)（\(values.count) 项）" : message }.sorted()
        return ThingsImportResult(snapshot: snapshot, warnings: grouped, sourceCounts: ["TMTask": tasks.count, "TMArea": areaRows.count, "TMTag": tagRows.count, "TMTaskTag": links.count, "TMAreaTag": areaLinks.count, "TMChecklistItem": checklistRows.count])
    }
}
