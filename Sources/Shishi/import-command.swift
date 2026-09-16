import Foundation
import ShishiCore

/// 本地批量迁移入口。只有显式传入 --import-things 与 --data-path 才写入目标库。
@MainActor
enum ImportCommand {
    static func runIfRequested(_ args: [String]) -> Bool {
        guard let sourceIndex = args.firstIndex(of: "--import-things") else { return false }
        guard args.indices.contains(sourceIndex + 1), let targetIndex = args.firstIndex(of: "--data-path"), args.indices.contains(targetIndex + 1) else {
            fputs("用法：Shishi --import-things <Things导出数据库> --data-path <拾事目标JSON>\n", stderr)
            exit(2)
        }
        let source = URL(fileURLWithPath: args[sourceIndex + 1]).standardizedFileURL.resolvingSymlinksInPath()
        let destination = URL(fileURLWithPath: args[targetIndex + 1]).standardizedFileURL.resolvingSymlinksInPath()
        do {
            // 避免将源数据库/包内部路径当作目标，保持原始导出副本只读。
            let packagePath = source.pathExtension == "thingsdatabase" ? source.path : source.deletingLastPathComponent().path
            guard destination.pathExtension == "json", !destination.path.hasPrefix(packagePath + "/") else {
                throw DataError.invalid("目标必须是源数据库目录以外的独立 JSON 文件")
            }
            let lock = try LibraryLock(dataURL: destination)
            try withExtendedLifetime(lock) {
                let result = try ThingsImporter.read(from: source)
                let store = TaskStore(fileURL: destination)
                if let error = store.errorMessage { throw DataError.invalid(error) }
                let stats = try store.mergeImported(result.snapshot)
                let report: [String: Any] = [
                    "added": stats.added, "updated": stats.updated,
                    "todos": store.todos.count, "projects": store.projects.count, "areas": store.areas.count,
                    "headings": store.projects.reduce(0) { $0 + $1.headings.count },
                    "checklistItems": store.todos.reduce(0) { $0 + $1.checklist.count },
                    "inbox": store.items(for: .inbox).count,
                    "todayTasks": store.items(for: .today).count, "todayProjects": store.projectItems(for: .today).count,
                    "today": store.items(for: .today).count + store.projectItems(for: .today).count,
                    "upcoming": store.items(for: .upcoming).count, "anytime": store.items(for: .anytime).count,
                    "someday": store.items(for: .someday).count, "logbook": store.items(for: .logbook).count,
                    "trashedTasks": store.items(for: .trash).count, "tags": store.allTags.count,
                    "warnings": result.warnings, "sourceCounts": result.sourceCounts
                ]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
            }
        } catch { fputs("导入失败：\(error.localizedDescription)\n", stderr); exit(1) }
        return true
    }
}
