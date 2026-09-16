import Foundation
import ShishiCore

enum TaskDateSelection: Equatable {
    case dated(Date, evening: Bool)
    case someday
    /// 清除安排：回到“随时”，与 Things 3 捷径中的「清除」同义。
    case clear
}

/// 解析使用调用方日历及时区；无年份日期、周几取今天起最近一次，完整日期不滚动年份。
struct TaskDateInput {
    var calendar: Calendar = .current
    var now: Date = Date()

    var today: Date { calendar.startOfDay(for: now) }

    func parse(_ text: String) -> TaskDateSelection? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "今天": return .dated(today, evening: false)
        case "今晚": return .dated(today, evening: true)
        case "明天": return calendar.date(byAdding: .day, value: 1, to: today).map { .dated($0, evening: false) }
        case "某天": return .someday
        case "随时", "清除": return .clear
        default: break
        }
        let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        if let index = weekdays.firstIndex(of: value == "周天" ? "周日" : value) {
            let delta = (index + 1 - calendar.component(.weekday, from: today) + 7) % 7
            return calendar.date(byAdding: .day, value: delta, to: today).map { .dated($0, evening: false) }
        }
        if let parts = captures(value, pattern: "^([0-9]{4})-([0-9]{2})-([0-9]{2})$"),
           let date = date(year: parts[0], month: parts[1], day: parts[2]), date >= today {
            return .dated(date, evening: false)
        }
        if let parts = captures(value, pattern: "^([0-9]{1,2})月([0-9]{1,2})日$" ) {
            let year = calendar.component(.year, from: today)
            // 包含闰日；下一个有效日期最多在八年内出现。
            for candidateYear in year...(year + 8) {
                if let candidate = date(year: candidateYear, month: parts[0], day: parts[1]), candidate >= today {
                    return .dated(candidate, evening: false)
                }
            }
        }
        return nil
    }

    func date(year: Int, month: Int, day: Int) -> Date? {
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.year, from: date) == year,
              calendar.component(.month, from: date) == month,
              calendar.component(.day, from: date) == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    func page(_ index: Int) -> [Date] {
        guard index >= 0, index < 10_000,
              let sunday = calendar.date(byAdding: .day, value: 1 - calendar.component(.weekday, from: today), to: today),
              let start = calendar.date(byAdding: .day, value: index * 28, to: sunday) else { return [] }
        return (0..<28).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    func reminder(dateText: String, timeText: String) -> Date? {
        guard case let .dated(day, _) = parse(dateText),
              let parts = captures(timeText.trimmingCharacters(in: .whitespacesAndNewlines), pattern: "^([0-9]{1,2}):([0-9]{2})$"),
              (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = parts[0]; components.minute = parts[1]
        guard let result = calendar.date(from: components), result > now,
              calendar.component(.hour, from: result) == parts[0],
              calendar.component(.minute, from: result) == parts[1] else { return nil }
        return result
    }

    func applying(_ selection: TaskDateSelection, to original: Todo) -> Todo {
        var copy = original
        switch selection {
        case let .dated(date, evening): copy.schedule = .dated; copy.startDate = date; copy.evening = evening
        case .someday: copy.schedule = .someday; copy.startDate = nil; copy.evening = false
        case .clear: copy.schedule = .anytime; copy.startDate = nil; copy.evening = false; copy.reminderDate = nil
        }
        return copy
    }

    private func captures(_ value: String, pattern: String) -> [Int]? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
        let parts = (1..<match.numberOfRanges).compactMap { index -> Int? in
            guard let range = Range(match.range(at: index), in: value) else { return nil }
            return Int(value[range])
        }
        return parts.count == match.numberOfRanges - 1 ? parts : nil
    }
}
