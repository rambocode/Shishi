import Foundation

/// 仅由显式 demo 初始化调用；所有内容均为合成数据，不读取外部应用。
public enum Demo {
    public static func snapshot(now: Date = Date(), calendar: Calendar = .current) -> Snapshot {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: today) ?? today }
        let work = Area(title: "工作", order: 0)
        let personal = Area(title: "个人", order: 1)
        let research = Heading(title: "调研", order: 0)
        let delivery = Heading(title: "交付", order: 1)
        let preparation = Heading(title: "准备", order: 0)
        let itinerary = Heading(title: "行程", order: 1)
        let routine = Heading(title: "日常习惯", order: 0)
        let launch = Project(title: "秋季产品发布", notes: "合成示例：梳理发布内容，并与团队确认交付节奏。", areaID: work.id, deadline: day(10), headings: [research, delivery], order: 0)
        let trip = Project(title: "周末近郊出游", notes: "合成示例：轻装出发，预留休息时间。", areaID: personal.id, deadline: day(5), headings: [preparation, itinerary], order: 1)
        let health = Project(title: "建立健康习惯", areaID: personal.id, headings: [routine], order: 2)
        var tasks = [
            Todo(title: "整理晨会记录", notes: "把新想法收集到这里，稍后安排。", tags: ["办公室"]),
            Todo(title: "想一想书房收纳方案", tags: ["家里"]),
            Todo(title: "确认发布页面文案", notes: "检查产品名称、按钮与帮助链接。", schedule: .dated, startDate: today, deadline: day(2), projectID: launch.id, areaID: work.id, headingID: delivery.id, tags: ["重点", "电脑"], checklist: [ChecklistItem(title: "核对标题", completed: true), ChecklistItem(title: "检查截图"), ChecklistItem(title: "发送审阅版本")]),
            Todo(title: "访谈两位试用者", schedule: .dated, startDate: today, projectID: launch.id, areaID: work.id, headingID: research.id, tags: ["沟通"]),
            Todo(title: "回复合作伙伴邮件", schedule: .dated, startDate: today, areaID: work.id, tags: ["沟通"], order: 4),
            Todo(title: "晚饭后散步 30 分钟", schedule: .dated, startDate: today, evening: true, projectID: health.id, areaID: personal.id, headingID: routine.id, tags: ["户外"], repeatRule: RepeatRule(unit: .day, afterCompletion: true)),
            Todo(title: "准备明天的早餐", schedule: .dated, startDate: today, evening: true, areaID: personal.id, tags: ["家里"], checklist: [ChecklistItem(title: "准备燕麦"), ChecklistItem(title: "洗好水果")]),
            Todo(title: "整理调研结论", schedule: .dated, startDate: day(1), deadline: day(3), projectID: launch.id, areaID: work.id, headingID: research.id, tags: ["电脑"]),
            Todo(title: "检查发布包", schedule: .dated, startDate: day(3), deadline: day(8), projectID: launch.id, areaID: work.id, headingID: delivery.id, checklist: [ChecklistItem(title: "验证安装"), ChecklistItem(title: "确认版本号")]),
            Todo(title: "查看周末天气", schedule: .dated, startDate: day(2), projectID: trip.id, areaID: personal.id, headingID: preparation.id, tags: ["出游"]),
            Todo(title: "规划步行路线", schedule: .anytime, projectID: trip.id, areaID: personal.id, headingID: itinerary.id, tags: ["户外", "出游"]),
            Todo(title: "准备出游背包", schedule: .anytime, deadline: day(4), projectID: trip.id, areaID: personal.id, headingID: preparation.id, checklist: [ChecklistItem(title: "水壶"), ChecklistItem(title: "防晒用品"), ChecklistItem(title: "充电宝")]),
            Todo(title: "阅读一本设计书", schedule: .anytime, areaID: work.id, tags: ["阅读"]),
            Todo(title: "练习拉伸 10 分钟", schedule: .anytime, projectID: health.id, areaID: personal.id, headingID: routine.id, tags: ["家里"], repeatRule: RepeatRule(unit: .week, interval: 2, afterCompletion: true)),
            Todo(title: "学做一道新菜", schedule: .someday, areaID: personal.id, tags: ["家里"]),
            Todo(title: "探索新的协作流程", schedule: .someday, areaID: work.id, tags: ["想法"]),
            Todo(title: "完成发布需求清单", status: .completed, schedule: .anytime, projectID: launch.id, areaID: work.id, headingID: research.id, tags: ["重点"], completedAt: day(-1)),
            Todo(title: "预约年度体检", status: .completed, schedule: .anytime, areaID: personal.id, completedAt: day(-2)),
            Todo(title: "取消重复的会议预约", status: .canceled, areaID: work.id, completedAt: day(-1)),
            Todo(title: "过时的购物清单", tags: ["家里"], deletedAt: day(-1))
        ]
        for index in tasks.indices { tasks[index].order = Double(index); tasks[index].createdAt = day(-7) }
        return Snapshot(todos: tasks, projects: [launch, trip, health], areas: [work, personal])
    }
}
