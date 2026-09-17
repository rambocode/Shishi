import Foundation
import ShishiCore

extension TaskStore {
    /// 立即保存完成状态，界面停留 1.5 秒后再隐藏项目；失败取消反馈，不延迟持久化。
    @discardableResult func finishProjectWithFeedback(_ id: UUID, status: TaskStatus) -> Bool {
        guard status == .completed else { return finishProject(id, status: status) }
        guard let project = projects.first(where: { $0.id == id && $0.deletedAt == nil }),
              !project.completed && (project.status == nil || project.status == .open) else { return false }
        projectCompletionFeedback.removeValue(forKey: id)?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.projectCompletionFeedback.removeValue(forKey: id) != nil else { return }
                NotificationCenter.default.post(name: Self.changed, object: self)
            }
        }
        // 同步变更通知发生前注册，以便侧栏和任务列表保留原行。
        projectCompletionFeedback[id] = work
        guard finishProject(id, status: status) else {
            projectCompletionFeedback.removeValue(forKey: id)?.cancel()
            NotificationCenter.default.post(name: Self.changed, object: self)
            return false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        return true
    }
}
