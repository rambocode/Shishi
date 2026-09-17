import Foundation
import ShishiCore

@MainActor final class TaskStore {
    static let changed = Notification.Name("ShishiStoreChanged")
    static let failed = Notification.Name("ShishiStoreFailed")
    private(set) var snapshot: Snapshot
    var errorMessage: String? {
        didSet {
            if errorMessage != nil { NotificationCenter.default.post(name: Self.failed, object: self) }
        }
    }
    private let file: SnapshotFile
    private var protectedFile = false
    private var past: [Snapshot] = []
    private var future: [Snapshot] = []
    /// 仅供界面短暂停留，不写入快照或撤销记录。
    var projectCompletionFeedback: [UUID: DispatchWorkItem] = [:]
    let preferences: GeneralPreferences
    private var preferencesObserver: NSObjectProtocol?
    var todos: [Todo] { snapshot.todos }
    var projects: [Project] { snapshot.projects.sorted { $0.order < $1.order } }
    var areas: [Area] { snapshot.areas.sorted { $0.order < $1.order } }
    var allTags: [String] {
        var tags = snapshot.tags ?? []
        tags += todos.filter { $0.deletedAt == nil }.flatMap(\.tags)
        tags += snapshot.projects.filter { $0.deletedAt == nil }.flatMap { $0.tags ?? [] }
        tags += snapshot.areas.flatMap { $0.tags ?? [] }
        return Array(Set(tags)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    var canUndo: Bool { !past.isEmpty && !protectedFile }
    var canRedo: Bool { !future.isEmpty && !protectedFile }

    init(fileURL: URL, demo: Bool = false, preferences: GeneralPreferences? = nil) {
        let preferences = preferences ?? .shared
        self.preferences = preferences
        file = SnapshotFile(url: fileURL)
        snapshot = Snapshot()
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do { snapshot = try file.load() }
            catch { protectedFile = true; errorMessage = "无法加载数据库，原文件已保护：\(error.localizedDescription)" }
        } else if demo {
            let value = Demo.snapshot()
            do { try file.write(value); snapshot = value }
            catch { errorMessage = error.localizedDescription }
        }
        preferencesObserver = NotificationCenter.default.addObserver(forName: GeneralPreferences.changed, object: preferences, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.refreshArchiveTiming() }
        }
        refreshArchiveTiming()
    }
    deinit { for work in projectCompletionFeedback.values { work.cancel() }; if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) } }

    /// 设置或跨日清理与手动归档均是可撤销的磁盘事务，写入失败保留 pending。
    @discardableResult func archiveCompletedItems() -> Bool {
        var value = snapshot
        CompletionArchive.apply(to: &value, timing: preferences.archiveTiming, now: Date(), force: true)
        guard value != snapshot else { return true }
        return commit(value)
    }
    @discardableResult func refreshArchiveTiming(now: Date = Date()) -> Bool {
        var value = snapshot
        CompletionArchive.apply(to: &value, timing: preferences.archiveTiming, now: now)
        guard value != snapshot else { return true }
        return commit(value)
    }

    func items(for route: Route, now: Date = Date()) -> [Todo] { Domain.items(in: snapshot, for: route, now: now) }
    func projectItems(for route: Route, now: Date = Date()) -> [Project] { Domain.projects(in: snapshot, for: route, now: now) }
    func todo(_ id: UUID) -> Todo? { todos.first { $0.id == id } }

    /// 磁盘写入成功才发布内存状态和通知；失败不改变撤销栈。
    @discardableResult private func commit(_ value: Snapshot, record: Bool = true) -> Bool {
        var value = value
        if record {
            let now = Date()
            let oldTodos = Dictionary(uniqueKeysWithValues: snapshot.todos.map { ($0.id, $0) })
            let oldProjects = Dictionary(uniqueKeysWithValues: snapshot.projects.map { ($0.id, $0) })
            for i in value.todos.indices {
                let item = value.todos[i]
                if item.status == .open { value.todos[i].pendingArchiveDate = nil }
                else if oldTodos[item.id]?.status == .open {
                    value.todos[i].pendingArchiveDate = preferences.archiveTiming == .immediately ? nil : (item.completedAt ?? now)
                }
            }
            for i in value.projects.indices {
                let p = value.projects[i]
                let closed = p.completed || p.status == .completed || p.status == .canceled
                if !closed { value.projects[i].pendingArchiveDate = nil }
                else if let old = oldProjects[p.id], !old.completed && (old.status == nil || old.status == .open) {
                    value.projects[i].pendingArchiveDate = preferences.archiveTiming == .immediately ? nil : now
                }
            }
            CompletionArchive.apply(to: &value, timing: preferences.archiveTiming, now: now)
        }
        guard !protectedFile else { errorMessage = "数据库已保护，请导入有效数据以恢复。"; return false }
        guard value != snapshot else { return true }
        do {
            try file.write(value)
            if record { past.append(snapshot); if past.count > 100 { past.removeFirst() }; future.removeAll() }
            snapshot = value; errorMessage = nil
            for id in Array(projectCompletionFeedback.keys) {
                if !value.projects.contains(where: { $0.id == id && $0.deletedAt == nil && $0.status == .completed }) {
                    projectCompletionFeedback.removeValue(forKey: id)?.cancel()
                }
            }
            NotificationCenter.default.post(name: Self.changed, object: self)
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    @discardableResult func save(_ todo: Todo) -> Bool {
        var value = snapshot
        var item = Domain.normalized(todo)
        if let projectID = item.projectID, let project = value.projects.first(where: { $0.id == projectID }) { item.areaID = project.areaID }
        if let index = value.todos.firstIndex(where: { $0.id == item.id }) {
            let old = value.todos[index]
            if old.status == .open && item.status == .completed && old.deletedAt == nil {
                var open = item; open.status = .open; open.completedAt = nil
                value.todos[index] = open
                guard Domain.complete(item.id, in: &value, now: item.completedAt ?? Date()) else { errorMessage = "无法计算下一个重复日期，原任务未修改。"; return false }
            } else { value.todos[index] = item }
        } else {
            value.todos.append(item)
        }
        return commit(value)
    }

    func toggle(_ id: UUID) {
        guard let index = snapshot.todos.firstIndex(where: { $0.id == id }), Domain.deletionDate(snapshot.todos[index], in: snapshot) == nil else { return }
        var value = snapshot
        if value.todos[index].status == .open {
            guard Domain.complete(id, in: &value) else { errorMessage = "无法计算下一个重复日期，原任务未修改。"; return }
        }
        else { value.todos[index].status = .open; value.todos[index].completedAt = nil }
        commit(value)
    }
    func cancel(_ id: UUID) {
        mutate(id) { if $0.status == .open && $0.deletedAt == nil { $0.status = .canceled; $0.completedAt = Date() } }
    }
    func trash(_ id: UUID) { mutate(id) { if $0.deletedAt == nil { $0.deletedAt = Date() } } }
    func restore(_ id: UUID) {
        mutate(id) { item in
            item.deletedAt = nil
            if let project = snapshot.projects.first(where: { $0.id == item.projectID }) {
                if project.deletedAt != nil {
                    // 单独恢复子任务不复活其他废纸篓内容；保留区域并移出已删除容器。
                    item.projectID = nil; item.headingID = nil
                    if item.areaID == nil { item.areaID = project.areaID }
                } else if project.headings.contains(where: { $0.id == item.headingID && $0.deletedAt != nil }) { item.headingID = nil }
            }
            item = Domain.normalized(item)
        }
    }
    func permanentlyDelete(_ id: UUID) {
        var value = snapshot
        value.todos.removeAll { $0.id == id && Domain.deletionDate($0, in: snapshot) != nil }
        commit(value)
    }
    private func mutate(_ id: UUID, _ operation: (inout Todo) -> Void) {
        var value = snapshot
        guard let index = value.todos.firstIndex(where: { $0.id == id }) else { return }
        operation(&value.todos[index]); commit(value)
    }

    /// 一个写盘及撤销事务复制完整项目树；失败返回 nil 且保留原状态。
    func duplicateProject(_ id: UUID) -> UUID? {
        var value = snapshot
        do {
            guard let copied = try ProjectOperations.duplicate(id, in: &value), commit(value) else { return nil }
            return copied
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    /// 标题分组操作的统一入口：在快照副本上执行，成功后一次写盘、一次撤销；失败返回 nil 并设置 errorMessage。
    @discardableResult func applyHeadingOperation<T>(_ operation: (inout Snapshot) throws -> T) -> T? {
        var value = snapshot
        do {
            let result = try operation(&value)
            return commit(value) ? result : nil
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    @discardableResult func saveProject(_ project: Project) -> Bool {
        var value = snapshot
        do {
            try ProjectOperations.save(project, in: &value)
            return commit(value)
        } catch { errorMessage = error.localizedDescription; return false }
    }
    /// 完成与重新开放均走统一保存入口，返回磁盘事务是否成功。
    @discardableResult func setProjectCompleted(_ id: UUID, completed: Bool) -> Bool {
        guard var project = snapshot.projects.first(where: { $0.id == id && $0.deletedAt == nil }) else { return false }
        if project.completed == completed && (project.status == nil || project.status == (completed ? .completed : .open)) { return true }
        project.completed = completed; project.status = completed ? .completed : .open
        return saveProject(project)
    }
    /// 项目与剩余任务一次保存、一次撤销；写入失败保留完整原状态。
    @discardableResult func finishProject(_ id: UUID, status: TaskStatus) -> Bool {
        var value = snapshot
        do {
            guard try ProjectOperations.finish(id, status: status, in: &value) else { return false }
            return commit(value)
        } catch { errorMessage = error.localizedDescription; return false }
    }
    @discardableResult func saveArea(_ area: Area) -> Bool {
        var value = snapshot; var item = area
        item.title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = value.areas.firstIndex(where: { $0.id == item.id }) { value.areas[index] = item }
        else { value.areas.append(item) }
        return commit(value)
    }
    func deleteProject(_ id: UUID) {
        guard let project = snapshot.projects.first(where: { $0.id == id }) else { return }
        var value = snapshot
        value.projects.removeAll { $0.id == id }
        for index in value.todos.indices where value.todos[index].projectID == id {
            value.todos[index].projectID = nil; value.todos[index].headingID = nil
            if value.todos[index].areaID == nil { value.todos[index].areaID = project.areaID }
            if value.todos[index].schedule == .inbox { value.todos[index].schedule = .anytime }
        }
        commit(value)
    }
    func trashProject(_ id: UUID) {
        var value = snapshot
        guard let index = value.projects.firstIndex(where: { $0.id == id }), value.projects[index].deletedAt == nil else { return }
        value.projects[index].deletedAt = Date(); commit(value)
    }
    func restoreProject(_ id: UUID) {
        var value = snapshot
        guard let index = value.projects.firstIndex(where: { $0.id == id }) else { return }
        value.projects[index].deletedAt = nil; commit(value)
    }
    func permanentlyDeleteProject(_ id: UUID) {
        guard snapshot.projects.contains(where: { $0.id == id && $0.deletedAt != nil }) else { return }
        var value = snapshot
        value.todos.removeAll { $0.projectID == id }
        value.projects.removeAll { $0.id == id }
        commit(value)
    }
    func deleteArea(_ id: UUID) {
        var value = snapshot
        value.areas.removeAll { $0.id == id }
        for index in value.projects.indices where value.projects[index].areaID == id { value.projects[index].areaID = nil }
        for index in value.todos.indices where value.todos[index].areaID == id { value.todos[index].areaID = nil }
        commit(value)
    }
    func move(_ id: UUID, to route: Route) { moveMany([id], to: route) }

    /// 单条与批量移动共用同一段归属规则，避免两处语义漂移。
    private func applyMove(_ item: inout Todo, to route: Route, in value: Snapshot) {
        guard item.deletedAt == nil && item.status == .open else { return }
        switch route {
        case .inbox: item.schedule = .inbox; item.startDate = nil; item.evening = false; item.projectID = nil; item.areaID = nil; item.headingID = nil
        case .today: item.schedule = .dated; item.startDate = Calendar.current.startOfDay(for: Date()); item.evening = false
        case .upcoming: item.schedule = .dated; item.startDate = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date())); item.evening = false
        case .anytime: item.schedule = .anytime; item.startDate = nil; item.evening = false
        case .someday: item.schedule = .someday; item.startDate = nil; item.evening = false
        case .project(let project): item.projectID = project; item.areaID = value.projects.first { $0.id == project }?.areaID; item.headingID = nil; if item.schedule == .inbox { item.schedule = .anytime }
        case .area(let area): item.areaID = area; item.projectID = nil; item.headingID = nil; if item.schedule == .inbox { item.schedule = .anytime }
        case .tag(let tag): if !item.tags.contains(tag) { item.tags.append(tag) }; item = Domain.normalized(item)
        case .search, .trash, .logbook: break
        }
    }

    /// 批量移动：整批合成一次写盘与一次撤销事务，失败时全部保持原状态。
    func moveMany(_ ids: [UUID], to route: Route) {
        guard !ids.isEmpty else { return }
        switch route {
        case .trash: trashMany(ids)
        case .logbook: completeMany(ids)
        default:
            var value = snapshot
            let base = snapshot
            for id in ids {
                guard let index = value.todos.firstIndex(where: { $0.id == id }) else { continue }
                applyMove(&value.todos[index], to: route, in: base)
            }
            commit(value)
        }
    }

    /// 批量安排开始日期；date 为 nil 表示清除安排回到“随时”。
    func scheduleMany(_ ids: [UUID], date: Date?, evening: Bool) {
        guard !ids.isEmpty else { return }
        guard let date else { moveMany(ids, to: .anytime); return }
        mutateMany(ids) { item in
            guard item.deletedAt == nil && item.status == .open else { return }
            item.schedule = .dated
            item.startDate = Calendar.current.startOfDay(for: date)
            item.evening = evening
        }
    }

    /// 批量完成。重复任务需要 Domain 逐条推进下一次日期，任一条失败即整批放弃。
    func completeMany(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var value = snapshot
        var changed = false
        for id in ids {
            guard let item = value.todos.first(where: { $0.id == id }),
                  item.status == .open, Domain.deletionDate(item, in: value) == nil else { continue }
            guard Domain.complete(id, in: &value) else { errorMessage = "无法计算下一个重复日期，整批未修改。"; return }
            changed = true
        }
        guard changed else { return }
        commit(value)
    }

    /// 批量重新打开已完成或已取消的待办，与 completeMany 构成 ⌘K 的另一半。
    func reopenMany(_ ids: [UUID]) {
        mutateMany(ids) { if $0.status != .open && $0.deletedAt == nil { $0.status = .open; $0.completedAt = nil; $0.pendingArchiveDate = nil } }
    }

    func cancelMany(_ ids: [UUID]) {
        mutateMany(ids) { if $0.status == .open && $0.deletedAt == nil { $0.status = .canceled; $0.completedAt = Date() } }
    }

    func trashMany(_ ids: [UUID]) {
        mutateMany(ids) { if $0.deletedAt == nil { $0.deletedAt = Date() } }
    }

    /// 批量永久删除：只移除确实处于废纸篓的条目，一次事务。
    func permanentlyDeleteMany(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var value = snapshot
        let targets = Set(ids)
        value.todos.removeAll { targets.contains($0.id) && Domain.deletionDate($0, in: snapshot) != nil }
        commit(value)
    }

    /// 批量恢复：废纸篓条目清除删除标记并移出已删除容器，日志簿条目重新变为开放，合成一次事务。
    func restoreMany(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        var value = snapshot
        let base = snapshot
        for id in ids {
            guard let index = value.todos.firstIndex(where: { $0.id == id }) else { continue }
            var item = value.todos[index]
            if item.deletedAt != nil {
                item.deletedAt = nil
                if let project = base.projects.first(where: { $0.id == item.projectID }) {
                    if project.deletedAt != nil {
                        // 单独恢复子任务不复活其他废纸篓内容；保留区域并移出已删除容器。
                        item.projectID = nil; item.headingID = nil
                        if item.areaID == nil { item.areaID = project.areaID }
                    } else if project.headings.contains(where: { $0.id == item.headingID && $0.deletedAt != nil }) { item.headingID = nil }
                }
            }
            item.status = .open; item.completedAt = nil; item.pendingArchiveDate = nil
            value.todos[index] = Domain.normalized(item)
        }
        commit(value)
    }

    /// 复制选中待办为新的开放任务，副本紧随原任务，整批一次事务。
    @discardableResult func duplicateMany(_ ids: [UUID]) -> [UUID] {
        guard !ids.isEmpty else { return [] }
        var value = snapshot
        var created: [UUID] = []
        for id in ids {
            guard let source = value.todos.first(where: { $0.id == id }), source.deletedAt == nil else { continue }
            var copy = source
            copy.id = UUID()
            copy.status = .open
            copy.completedAt = nil
            copy.pendingArchiveDate = nil
            copy.createdAt = Date()
            // 副本不继承来源 ID，否则再次导入 Things 数据会把副本当作同一条记录覆盖。
            copy.source = nil
            copy.order = source.order + 0.5
            copy.checklist = source.checklist.map { var c = $0; c.id = UUID(); return c }
            value.todos.append(Domain.normalized(copy))
            created.append(copy.id)
        }
        guard !created.isEmpty, commit(value) else { return [] }
        return created
    }

    /// 批量写入整条待办（标签、截止日期等需要整体替换的字段）。
    func saveMany(_ todos: [Todo]) {
        guard !todos.isEmpty else { return }
        var value = snapshot
        for todo in todos {
            var item = Domain.normalized(todo)
            if let projectID = item.projectID, let project = value.projects.first(where: { $0.id == projectID }) { item.areaID = project.areaID }
            if let index = value.todos.firstIndex(where: { $0.id == item.id }) { value.todos[index] = item } else { value.todos.append(item) }
        }
        commit(value)
    }

    /// 多条待办的就地修改合并为一次事务；跳过不存在的 id。
    private func mutateMany(_ ids: [UUID], _ operation: (inout Todo) -> Void) {
        guard !ids.isEmpty else { return }
        var value = snapshot
        for id in ids {
            guard let index = value.todos.firstIndex(where: { $0.id == id }) else { continue }
            operation(&value.todos[index])
        }
        commit(value)
    }
    func reorder(_ ids: [UUID]) {
        let known = Set(snapshot.todos.map(\.id))
        guard Set(ids).count == ids.count, ids.allSatisfy({ known.contains($0) }) else { errorMessage = "排序包含无效或重复任务"; return }
        var value = snapshot
        // 未列出的任务保留相对顺序，部分列表拖拽不会制造相同排序值。
        let positions = value.todos.indices.sorted { value.todos[$0].order < value.todos[$1].order }
        let selected = Set(ids)
        var iterator = ids.makeIterator()
        let ordered = positions.map { selected.contains(value.todos[$0].id) ? iterator.next()! : value.todos[$0].id }
        let ranks = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element, Double($0.offset)) })
        for index in value.todos.indices { value.todos[index].order = ranks[value.todos[index].id]! }
        commit(value)
    }
    func reorderToday(_ ids: [UUID]) {
        let known = Set(snapshot.todos.map(\.id) + snapshot.projects.map(\.id))
        guard Set(ids).count == ids.count, ids.allSatisfy({ known.contains($0) }) else { errorMessage = "今天排序包含无效或重复对象"; return }
        guard !ids.isEmpty else { return }
        let selected = Set(ids)
        let visible = Set(items(for: .today).map(\.id) + projectItems(for: .today).map(\.id)).union(selected)
        var entries: [(id: UUID, rank: Double)] = []
        for task in snapshot.todos where visible.contains(task.id) {
            entries.append((task.id, task.source?.metadata["todayIndex"].flatMap(Double.init) ?? task.order))
        }
        for project in snapshot.projects where visible.contains(project.id) {
            entries.append((project.id, project.source?.metadata["todayIndex"].flatMap(Double.init) ?? project.order))
        }
        guard entries.allSatisfy({ $0.rank.isFinite }) else { errorMessage = "今天排序值无效"; return }
        entries.sort { $0.rank == $1.rank ? $0.id.uuidString < $1.id.uuidString : $0.rank < $1.rank }
        var iterator = ids.makeIterator()
        let order = entries.map { selected.contains($0.id) ? iterator.next()! : $0.id }
        var ranks: [UUID: Double] = [:]
        var cursor = 0, needsFrontPlacement = false
        // 在未参与项之间分配稀疏排序值，不重写未参与项，也不影响普通 order。
        while cursor < order.count {
            guard selected.contains(order[cursor]) else { cursor += 1; continue }
            let start = cursor
            while cursor < order.count && selected.contains(order[cursor]) { cursor += 1 }
            let count = cursor - start
            let lower = start > 0 ? entries[start - 1].rank : nil
            let upper = cursor < entries.count ? entries[cursor].rank : nil
            if let lower, let upper, lower >= upper { needsFrontPlacement = true; break }
            for index in 0..<count {
                let rank: Double
                if let lower, let upper { rank = lower + (upper - lower) * Double(index + 1) / Double(count + 1) }
                else if let lower { rank = lower + Double(index + 1) }
                else if let upper { rank = upper - Double(count - index) }
                else { rank = Double(index) }
                ranks[order[start + index]] = rank
            }
        }
        if needsFrontPlacement {
            // 旧库重复排序值没有可插入间隙；将参与序列置前，其他项仍维持原相对顺序。
            let minimum = entries.map(\.rank).min() ?? 0
            for (index, id) in ids.enumerated() { ranks[id] = minimum - Double(ids.count - index) }
        }
        guard ranks.values.allSatisfy({ $0.isFinite }) else { errorMessage = "无法生成有效今天排序值"; return }
        var value = snapshot
        for index in value.todos.indices {
            let id = value.todos[index].id
            guard let rank = ranks[id] else { continue }
            if value.todos[index].source == nil { value.todos[index].source = SourceInfo(provider: "Shishi", identifier: id.uuidString) }
            value.todos[index].source?.metadata["todayIndex"] = String(rank)
        }
        for index in value.projects.indices {
            let id = value.projects[index].id
            guard let rank = ranks[id] else { continue }
            if value.projects[index].source == nil { value.projects[index].source = SourceInfo(provider: "Shishi", identifier: id.uuidString) }
            value.projects[index].source?.metadata["todayIndex"] = String(rank)
        }
        commit(value)
    }
    func undo() {
        guard let previous = past.last else { return }
        let current = snapshot
        if commit(previous, record: false) { past.removeLast(); future.append(current) }
    }
    func redo() {
        guard let next = future.last else { return }
        let current = snapshot
        if commit(next, record: false) { future.removeLast(); past.append(current) }
    }
    func exportData(to url: URL) throws {
        guard !protectedFile else { throw DataError.invalid("数据库加载失败，不能导出空数据") }
        guard url.standardizedFileURL != file.url.standardizedFileURL else { throw DataError.invalid("导出位置不能是当前数据库") }
        try SnapshotFile(url: url).write(snapshot)
    }
    func importData(from url: URL) throws {
        var imported = try SnapshotFile(url: url).load()
        // 恢复备份与当前归档策略共用一次写盘/撤销事务，避免重启才改变可见状态。
        CompletionArchive.apply(to: &imported, timing: preferences.archiveTiming, now: Date())
        try file.backup()
        try file.write(imported)
        if protectedFile { past.removeAll() } else { past.append(snapshot) }
        future.removeAll()
        snapshot = imported; protectedFile = false; errorMessage = nil
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// 合并不恢复本地回收站；验证和备份成功后才原子替换磁盘，随后更新内存与撤销栈。
    @discardableResult func mergeImported(_ incoming: Snapshot) throws -> (added: Int, updated: Int) {
        do {
            guard !protectedFile else { throw DataError.invalid("数据库已保护，请先恢复有效数据库再合并。") }
            let result = try ImportedMerge.merge(incoming, into: snapshot)
            try file.backup()
            guard commit(result.snapshot) else { throw DataError.invalid(errorMessage ?? "合并保存失败") }
            return (result.added, result.updated)
        } catch {
            if errorMessage != error.localizedDescription { errorMessage = error.localizedDescription }
            throw error
        }
    }
}
