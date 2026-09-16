import Foundation

enum ThingsValues {
    static func source(_ row: SQLiteRow, id: String) throws -> SourceInfo {
        var metadata: [String: String] = [:]
        let title = try row.text("title") ?? ""
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata["originalTitle"] = title
            metadata["originalTitleWasNull"] = row["title"] == nil ? "true" : "false"
        }
        for key in ["start", "startDate", "startBucket", "deadline", "deadlineSuppressionDate", "todayIndex", "todayIndexReferenceDate", "reminderTime", "index", "visible"] {
            if let value = try row.integer(key) { metadata[key] = String(value) }
        }
        for key in ["area", "project", "heading", "actionGroup", "contact"] {
            if let value = try row.text(key) { metadata["source:" + key] = value }
        }
        for key in ["creationDate", "stopDate", "userModificationDate", "repeaterMigrationDate"] {
            if let value = try row.number(key) { metadata[key] = String(value) }
        }
        return SourceInfo(provider: "Things3", identifier: id, metadata: metadata)
    }
    static func title(_ row: SQLiteRow, kind: String, warnings: inout [String]) throws -> String {
        let text = try row.text("title") ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append("一项空标题\(kind)已用占位标题保留，未丢弃原记录。")
            return "未命名\(kind)（Things 导入）"
        }
        return text
    }
    /// 公开 things.py 的 YYYYYYYYYYYMMMMDDDDD0000000；按本地 Gregorian 日期重建。
    /// https://github.com/thingsapi/things.py/blob/main/things/database.py
    static func date(_ value: Int64?) throws -> Date? {
        guard let value, value != 0 else { return nil }
        // 上游编码使用 year << 16；解码示例的 11-bit 掩码不能作为年份校验上限。
        guard value > 0, (1...9999).contains(value >> 16), value & 127 == 0 else { throw DataError.invalid("Things 日期位编码无效") }
        let year = Int(value >> 16), month = Int((value >> 12) & 15), day = Int((value >> 7) & 31)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        guard year > 0, (1...12).contains(month), (1...31).contains(day),
              let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: year, month: month, day: day) else { throw DataError.invalid("Things 日期不是有效日历日期") }
        return date
    }
    static func timestamp(_ value: Double?) throws -> Date? {
        guard let value else { return nil }
        guard value.isFinite, abs(value) <= 253_402_300_799 else { throw DataError.invalid("Things 时间戳无效") }
        return Date(timeIntervalSince1970: value)
    }
    static func status(_ value: Int64?) throws -> TaskStatus {
        switch value { case 0: return .open; case 2: return .canceled; case 3: return .completed; default: throw DataError.invalid("无法识别 Things 任务状态") }
    }
    static func schedule(_ value: Int64?, date: Date?) throws -> Schedule {
        let result: Schedule
        switch value { case 0: result = .inbox; case 1: result = .anytime; case 2: result = .someday; default: throw DataError.invalid("无法识别 Things 安排类型") }
        return date == nil ? result : .dated
    }
    static func recurrence(_ row: SQLiteRow, notes: inout String, warnings: inout [String]) throws {
        for key in ["rt1_recurrenceRule", "recurrenceRule", "repeatRule"] {
            guard let value = row[key] else { continue }
            let raw: String
            switch value {
            case .text(let text): raw = text
            case .blob(let data): raw = String(data: data, encoding: .utf8) ?? "base64:" + data.base64EncodedString()
            default: throw DataError.invalid("Things 重复规则存储类型无效")
            }
            if !raw.isEmpty {
                notes += "\n\n[Things 原始重复规则：\(key)]\n" + raw
                warnings.append("一项重复规则无法可靠转换，原始内容已保留在备注；导入后不会自动重复。")
            }
        }
    }
}
