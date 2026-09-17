import AppKit
import ShishiCore

extension TaskListController {
    /// 完成立即持久化，原行显示勾选 1.5 秒后再按当前列表规则移除。
    /// 再次点击恢复开放状态；保存失败则立即还原显示，不保留虚假的完成反馈。
    func toggleTaskWithFeedback(_ id: UUID) {
        guard finishInlineEditing(), let task = store.todo(id),
              Domain.deletionDate(task, in: store.snapshot) == nil else { return }
        completionFeedback.removeValue(forKey: id)?.cancel()
        if task.status != .open {
            store.toggle(id)
            reload()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.completionFeedback.removeValue(forKey: id) != nil else { return }
                self.animatesCompletionRemoval = true
                defer { self.animatesCompletionRemoval = false }
                self.reload()
            }
        }
        // Store 的通知同步刷新列表，因此必须先记录反馈，再提交完成。
        completionFeedback[id] = work
        store.toggle(id)
        guard store.todo(id)?.status == .completed else {
            completionFeedback.removeValue(forKey: id)?.cancel()
            reload()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// 离开列表后不携带旧列表的临时行，也不让旧回调刷新新页面。
    func clearCompletionFeedback() {
        for work in completionFeedback.values { work.cancel() }
        completionFeedback.removeAll()
    }
}
