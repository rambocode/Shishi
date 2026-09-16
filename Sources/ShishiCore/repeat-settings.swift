import Foundation

/// 重复规则的中文文案，卡片摘要、菜单与面板共用，避免同一规则出现两种说法。
public enum RepeatText {
    public static func summary(_ rule: RepeatRule) -> String {
        if rule.afterCompletion { return "上一个待办事项完成后 \(rule.interval) \(unit(rule.unit, count: rule.interval))" }
        if rule.interval == 1 {
            switch rule.unit {
            case .day: return "每天"
            case .week: return "每周"
            case .month: return "每月"
            case .year: return "每年"
            }
        }
        return "每 \(rule.interval) \(unit(rule.unit, count: rule.interval))"
    }
    /// 带前缀的整句，用于卡片内的重复说明行。
    public static func sentence(_ rule: RepeatRule) -> String { "重复 " + summary(rule) }
    private static func unit(_ value: RepeatUnit, count: Int) -> String {
        switch value {
        case .day: return "天"
        case .week: return "周"
        case .month: return count == 1 ? "月" : "个月"
        case .year: return "年"
        }
    }
}

/// 重复面板的一次编辑结果：重复规则本身，以及随规则一起设置的提醒时刻与截止日期偏移。
/// 面板只产出这个值，写回任务的换算集中在 applied(to:) 里，方便直接测试。
public struct TaskRepeatSettings: Equatable {
    public var rule: RepeatRule?
    /// 仅保留时与分；nil 表示不设置提醒。
    public var reminder: DateComponents?
    /// 截止日期相对开始日期的天数；nil 表示不设置截止日期。
    public var deadlineOffsetDays: Int?

    public init(rule: RepeatRule? = nil, reminder: DateComponents? = nil, deadlineOffsetDays: Int? = nil) {
        self.rule = rule
        self.reminder = reminder.map { DateComponents(hour: $0.hour, minute: $0.minute) }
        self.deadlineOffsetDays = deadlineOffsetDays.map { max(0, $0) }
    }

    /// 读取任务当前状态作为面板初值：提醒只取时分，截止日期换算成与开始日期的天数差。
    public static func from(_ todo: Todo, calendar: Calendar = .current) -> TaskRepeatSettings {
        var settings = TaskRepeatSettings(rule: todo.repeatRule)
        if let reminder = todo.reminderDate, reminder.timeIntervalSinceReferenceDate.isFinite {
            settings.reminder = calendar.dateComponents([.hour, .minute], from: reminder)
        }
        if let deadline = todo.deadline, deadline.timeIntervalSinceReferenceDate.isFinite {
            let start = calendar.startOfDay(for: todo.startDate ?? deadline)
            settings.deadlineOffsetDays = max(0, calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: deadline)).day ?? 0)
        }
        return settings
    }

    /// 写回任务。重复必须有开始日期，否则下一实例没有锚点，所以缺失时补成今天；
    /// 取消重复只清规则，不动用户单独设过的提醒和截止日期。
    public func applied(to todo: Todo, now: Date = Date(), calendar: Calendar = .current) -> Todo {
        var result = todo
        result.repeatRule = rule
        guard rule != nil else { return result }
        if result.schedule != .dated || result.startDate == nil {
            result.schedule = .dated
            result.startDate = calendar.startOfDay(for: now)
            result.evening = false
        }
        let start = result.startDate ?? calendar.startOfDay(for: now)
        if let hour = reminder?.hour, let minute = reminder?.minute {
            result.reminderDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start)
        } else {
            result.reminderDate = nil
        }
        if let offset = deadlineOffsetDays {
            result.deadline = calendar.date(byAdding: .day, value: max(0, offset), to: start)
            result.deadlineSuppressionDate = nil
        } else {
            result.deadline = nil
        }
        return result
    }
}
