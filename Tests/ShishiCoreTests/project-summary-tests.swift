import Foundation
import XCTest
import ShishiCore

final class ProjectSummaryTests: XCTestCase {
    func testCountsExcludeChecklistAndCancellationFromDenominator() {
        let project = Project(title: "项目")
        let tasks = [
            Todo(title: "开放", projectID: project.id, checklist: [ChecklistItem(title: "检查项", completed: true)]),
            Todo(title: "完成", status: .completed, projectID: project.id),
            Todo(title: "取消", status: .canceled, projectID: project.id)
        ]
        let summary = ProjectSummary(project: project, tasks: tasks)
        XCTAssertEqual(summary.openCount, 1)
        XCTAssertEqual(summary.completedCount, 1)
        XCTAssertEqual(summary.canceledCount, 1)
        XCTAssertEqual(summary.totalCount, 3)
        XCTAssertEqual(summary.fraction, 0.5)
        XCTAssertEqual(summary.recordedItems.count, 2)
    }

    func testDeletedEntitiesAndProjectIDOwnership() {
        let date = Date(timeIntervalSince1970: 100)
        let live = Heading(title: "正常")
        let deleted = Heading(title: "已删除", deletedAt: date)
        var project = Project(title: "同名项目", headings: [live, deleted])
        let other = Project(title: "同名项目")
        let tasks = [
            Todo(title: "无标题", projectID: project.id),
            Todo(title: "正常标题", status: .completed, projectID: project.id, headingID: live.id),
            Todo(title: "删除标题", status: .canceled, projectID: project.id, headingID: deleted.id),
            Todo(title: "删除任务", projectID: project.id, deletedAt: date),
            Todo(title: "别的项目", projectID: other.id, headingID: live.id),
            Todo(title: "未归属", headingID: live.id)
        ]
        let summary = ProjectSummary(project: project, tasks: tasks)
        XCTAssertEqual(summary.totalCount, 2)
        XCTAssertEqual(summary.openCount, 1)
        XCTAssertEqual(summary.completedCount, 1)
        XCTAssertEqual(summary.canceledCount, 0)
        XCTAssertEqual(summary.recordedItems.map(\.title), ["正常标题"])
        project.deletedAt = date
        let deletedSummary = ProjectSummary(project: project, tasks: tasks)
        XCTAssertEqual(deletedSummary.totalCount, 0)
        XCTAssertEqual(deletedSummary.fraction, 0)
        XCTAssertTrue(deletedSummary.recordedItems.isEmpty)
    }

    func testEmptyAndStatusChangesRecomputeFraction() {
        let project = Project(title: "项目", completed: true)
        XCTAssertEqual(ProjectSummary(project: project, tasks: []).fraction, 0)
        var task = Todo(title: "任务", projectID: project.id)
        XCTAssertEqual(ProjectSummary(project: project, tasks: [task]).fraction, 0)
        task.status = .completed
        XCTAssertEqual(ProjectSummary(project: project, tasks: [task]).fraction, 1)
        task.status = .canceled
        let canceled = ProjectSummary(project: project, tasks: [task])
        XCTAssertEqual(canceled.fraction, 0)
        XCTAssertEqual(canceled.canceledCount, 1)
        XCTAssertEqual(canceled.totalCount, 1)
        task.status = .open
        XCTAssertTrue(ProjectSummary(project: project, tasks: [task]).recordedItems.isEmpty)
    }

    func testRecordedItemsUseCompletionOrCreationTimeWithStableTies() {
        let project = Project(title: "项目")
        let early = Date(timeIntervalSince1970: 10)
        let recent = Date(timeIntervalSince1970: 30)
        let tasks = [
            Todo(title: "较早完成", status: .completed, projectID: project.id, createdAt: recent, completedAt: early),
            Todo(title: "同时间取消", status: .canceled, projectID: project.id, createdAt: recent),
            Todo(title: "同时间完成", status: .completed, projectID: project.id, createdAt: early, completedAt: recent),
            Todo(title: "开放", projectID: project.id, createdAt: recent)
        ]
        XCTAssertEqual(ProjectSummary(project: project, tasks: tasks).recordedItems.map(\.id),
                       [tasks[1].id, tasks[2].id, tasks[0].id])
    }

    func testRepeatTemplatesAreExcludedButHistoricalInstancesRemain() {
        let project = Project(title: "项目")
        let template = SourceInfo(provider: "things", identifier: "template", metadata: ["repeatTemplate": "true"])
        let instance = SourceInfo(provider: "things", identifier: "instance", metadata: ["repeatingTemplateID": "template"])
        let tasks = [
            Todo(title: "开放模板", projectID: project.id, source: template),
            Todo(title: "完成模板", status: .completed, projectID: project.id, source: template),
            Todo(title: "取消模板", status: .canceled, projectID: project.id, source: template),
            Todo(title: "历史完成实例", status: .completed, projectID: project.id, source: instance),
            Todo(title: "当前重复任务", projectID: project.id, repeatRule: RepeatRule(unit: .day))
        ]
        let summary = ProjectSummary(project: project, tasks: tasks)
        XCTAssertEqual(summary.totalCount, 2)
        XCTAssertEqual(summary.openCount, 1)
        XCTAssertEqual(summary.completedCount, 1)
        XCTAssertEqual(summary.canceledCount, 0)
        XCTAssertEqual(summary.fraction, 0.5)
        XCTAssertEqual(summary.recordedItems.map(\.id), [tasks[3].id])
    }
}
