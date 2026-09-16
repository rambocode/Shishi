import Foundation

enum ThingsRepeat {
    /// 只转换单一、无限且无提醒偏移的规则；复杂规则保留原文及 schema 键，不猜测。
    /// fu/tp 映射依据公开源码 github.com/kern/dongxi 与 things-cloud-sdk/repeat.go。
    static func read(_ row: SQLiteRow, source: String, notes: inout String, warnings: inout [String]) throws -> (SourceInfo, RepeatRule?) {
        var metadata = try ThingsValues.source(row, id: source).metadata
        if let template = try row.text("rt1_repeatingTemplate", "repeatingTemplate") { metadata["repeatingTemplateID"] = template }
        for key in ["rt1_instanceCreationStartDate", "rt1_nextInstanceStartDate", "rt1_afterCompletionReferenceDate", "rt1_instanceCreationPaused", "rt1_instanceCreationCount"] {
            if let value = try row.integer(key) { metadata[key] = String(value) }
        }
        var converted: RepeatRule?
        for key in ["repeater", "rt1_recurrenceRule", "recurrenceRule", "repeatRule"] {
            guard let value = row[key] else { continue }
            let data: Data
            switch value {
            case .text(let text): data = Data(text.utf8)
            case .blob(let blob): data = blob
            default: throw DataError.invalid("Things 重复规则存储类型无效")
            }
            guard !data.isEmpty else { continue }
            metadata["raw:" + key] = data.base64EncodedString()
            metadata["repeatTemplate"] = "true"
            let object = (try? JSONSerialization.jsonObject(with: data)) ?? (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
            let dictionary = object as? [String: Any]
            var ruleMetadata: [String: String] = [:]
            let candidate = dictionary.flatMap { convert($0, metadata: &ruleMetadata) }
            if converted == nil, let candidate, try !row.flag("rt1_instanceCreationPaused", "instanceCreationPaused") {
                converted = candidate
                metadata.merge(ruleMetadata) { _, new in new }
            } else {
                let raw = String(data: data, encoding: .utf8) ?? "base64:" + data.base64EncodedString()
                notes += "\n\n[Things 原始重复规则：\(key)]\n" + raw
                warnings.append("一项重复规则包含不支持的细节或处于暂停状态，原始规则已保留，不自动生成周期。")
            }
        }
        return (SourceInfo(provider: "Things3", identifier: source, metadata: metadata), converted)
    }
    private static func convert(_ value: [String: Any], metadata: inout [String: String]) -> RepeatRule? {
        func integer(_ key: String) -> Int? {
            guard let number = value[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                  number.doubleValue.rounded() == number.doubleValue, abs(number.doubleValue) < Double(Int.max) else { return nil }
            return number.intValue
        }
        guard integer("rrv") == 4, let type = integer("tp"), type == 0 || type == 1,
              let frequency = integer("fu"), let interval = integer("fa"), (1...10000).contains(interval),
              integer("rc") == 0, integer("ts") == 0, integer("ed") == 64_092_211_200,
              let offsets = value["of"] as? [[String: Any]], offsets.count == 1 else { return nil }
        let allowed = Set(["rrv", "tp", "fu", "fa", "of", "ia", "sr", "rc", "ts", "ed"])
        guard Set(value.keys).isSubset(of: allowed) else { return nil }
        let offset = offsets[0]
        func detail(_ key: String) -> Int? {
            guard let number = offset[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue, abs(number.doubleValue) < 10000 else { return nil }
            return number.intValue
        }
        let unit: RepeatUnit
        switch frequency {
        case 16:
            guard Set(offset.keys) == ["dy"], detail("dy") == 0 else { return nil }
            unit = .day
        case 8:
            guard Set(offset.keys) == ["dy"], let day = detail("dy"), (-1...30).contains(day) else { return nil }
            unit = .month
            if type == 1 { metadata["repeatDay"] = String(day == -1 ? -1 : day + 1) }
            else if day != 0 { return nil }
        case 256:
            guard Set(offset.keys) == ["wd"], let weekday = detail("wd"), (0...6).contains(weekday), type == 1 else { return nil }
            unit = .week; metadata["repeatWeekday"] = String(weekday + 1)
        case 4:
            guard Set(offset.keys) == ["dy", "mo"], let day = detail("dy"), let month = detail("mo"), (-1...30).contains(day), (0...11).contains(month), type == 1 else { return nil }
            unit = .year; metadata["repeatDay"] = String(day == -1 ? -1 : day + 1); metadata["repeatMonth"] = String(month + 1)
        default: return nil
        }
        return RepeatRule(unit: unit, interval: interval, afterCompletion: type == 0)
    }
}
