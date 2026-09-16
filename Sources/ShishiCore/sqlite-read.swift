import Foundation
import CSQLite

enum SQLiteValue {
    case integer(Int64), real(Double), text(String), blob(Data)
}
typealias SQLiteRow = [String: SQLiteValue]

/// 连接只打开用户指定文件；不搜索默认目录，不迁移、不修改源 schema。
final class SQLiteReader {
    private var database: OpaquePointer?
    init(url: URL) throws {
        guard url.isFileURL else { throw DataError.invalid("请选择本地 SQLite 文件") }
        let code = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, sqlite3_db_readonly(database, "main") == 1 else {
            if database != nil { sqlite3_close(database); database = nil }
            throw DataError.invalid("无法只读打开 Things 数据库（SQLite \(code)），请使用已授权的导出副本。")
        }
        sqlite3_busy_timeout(database, 3000)
    }
    deinit { sqlite3_close(database) }

    func query(_ sql: String) throws -> [SQLiteRow] {
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw DataError.invalid("Things 数据库查询失败（SQLite \(prepared)）") }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) == 1 else { throw DataError.invalid("拒绝非只读 Things 查询") }
        var result: [SQLiteRow] = []
        var code = sqlite3_step(statement)
        while code == SQLITE_ROW {
            var row: SQLiteRow = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, index))
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row[name] = .integer(sqlite3_column_int64(statement, index))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(statement, index))
                case SQLITE_TEXT:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    guard let pointer = sqlite3_column_text(statement, index), let text = String(bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8) else { throw DataError.invalid("Things 字段不是有效 UTF-8") }
                    row[name] = .text(text)
                case SQLITE_BLOB:
                    let count = Int(sqlite3_column_bytes(statement, index))
                    row[name] = .blob(sqlite3_column_blob(statement, index).map { Data(bytes: $0, count: count) } ?? Data())
                case SQLITE_NULL: break
                default: throw DataError.invalid("无法识别 Things 字段类型")
                }
            }
            result.append(row)
            code = sqlite3_step(statement)
        }
        guard code == SQLITE_DONE else { throw DataError.invalid("Things 数据库读取失败（SQLite \(code)）") }
        return result
    }

    func table(_ name: String, required: [String], alternatives: [[String]] = [], recommended: [String] = [], optional: [String] = [], warnings: inout [String]) throws -> [SQLiteRow] {
        // name 只能来自代码中的固定表名，不接受源数据拼接 SQL。
        let columns = try query("PRAGMA table_info(\"\(name)\")").compactMap { row -> String? in
            if case .text(let text)? = row["name"] { return text }; return nil
        }
        guard !columns.isEmpty else {
            if optional.contains("table") { warnings.append("源库没有 \(name)，未导入该类内容。"); return [] }
            throw DataError.invalid("缺少 Things 数据表 \(name)")
        }
        guard required.allSatisfy({ columns.contains($0) }) else { throw DataError.invalid("\(name) 缺少必需字段，无法可靠导入") }
        guard alternatives.allSatisfy({ names in names.contains { columns.contains($0) } }) else { throw DataError.invalid("\(name) 缺少关联字段，无法可靠导入") }
        let missing = recommended.filter { !columns.contains($0) }
        if !missing.isEmpty { warnings.append("\(name) 不包含 \(missing.joined(separator: ", "))，这些字段无法导入。") }
        return try query("SELECT * FROM \"\(name)\"")
    }
}

extension Dictionary where Key == String, Value == SQLiteValue {
    func text(_ names: String...) throws -> String? { try text(names) }
    func text(_ names: [String]) throws -> String? {
        for name in names where self[name] != nil {
            guard case .text(let value)? = self[name] else { throw DataError.invalid("Things 文本字段 \(name) 类型无效") }
            return value.isEmpty ? nil : value
        }
        return nil
    }
    func requiredText(_ names: String...) throws -> String {
        guard let value = try text(names), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw DataError.invalid("Things 必需文本字段为空") }
        return value
    }
    func number(_ names: String...) throws -> Double? {
        for name in names where self[name] != nil {
            switch self[name] {
            case .integer(let value): return Double(value)
            case .real(let value) where value.isFinite: return value
            default: throw DataError.invalid("Things 数值字段 \(name) 类型无效")
            }
        }
        return nil
    }
    func integer(_ names: String...) throws -> Int64? {
        for name in names where self[name] != nil {
            guard case .integer(let value)? = self[name] else { throw DataError.invalid("Things 整数字段 \(name) 类型无效") }
            return value
        }
        return nil
    }
    func flag(_ names: String...) throws -> Bool {
        for name in names where self[name] != nil {
            guard case .integer(let value)? = self[name], value == 0 || value == 1 else { throw DataError.invalid("Things 布尔字段 \(name) 无效") }
            return value == 1
        }
        return false
    }
}
