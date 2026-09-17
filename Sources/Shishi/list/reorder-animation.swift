import AppKit
import QuartzCore

/// 一次连续分组换位的最小行移动计划，构建成本为 O(n)。
/// 非连续区块换位返回 nil，让宿主走普通刷新，避免复杂重排阻塞主线程。
struct RowReorderPlan {
    struct Move: Equatable {
        let source: Int
        let destination: Int
    }
    let moves: [Move]

    init?(from source: [String], to destination: [String]) {
        guard source.count == destination.count, Set(source).count == source.count,
              Set(source) == Set(destination) else { return nil }
        guard let start = source.indices.first(where: { source[$0] != destination[$0] }) else {
            moves = []; return
        }
        let end = source.indices.last(where: { source[$0] != destination[$0] })! + 1
        guard let split = source[start..<end].firstIndex(of: destination[start]) else { return nil }
        let firstCount = split - start, secondCount = end - split
        guard firstCount > 0, secondCount > 0,
              source[split..<end].elementsEqual(destination[start..<(start + secondCount)]),
              source[start..<split].elementsEqual(destination[(start + secondCount)..<end]) else { return nil }
        // A+B -> B+A：只移动 A、B 中较短的一个，native moveRow 会让其余行整体让位。
        if firstCount <= secondCount {
            moves = (0..<firstCount).map { _ in Move(source: start, destination: end - 1) }
        } else {
            moves = (0..<secondCount).map { Move(source: split + $0, destination: start + $0) }
        }
    }
}

extension ListTableView {
    /// 完成反馈结束时淡出移除行，原生更新让后续行平滑补位；复杂换序退回完整刷新。
    @discardableResult
    func animateCompletionRemoval(from source: [String], to destination: [String]) -> Bool {
        guard source.count == numberOfRows, Set(source).count == source.count,
              Set(destination).count == destination.count else { return false }
        let oldIDs = Set(source), newIDs = Set(destination)
        guard source.filter({ newIDs.contains($0) }) == destination.filter({ oldIDs.contains($0) }) else { return false }
        let removed = IndexSet(source.indices.filter { !newIDs.contains(source[$0]) })
        let inserted = IndexSet(destination.indices.filter { !oldIDs.contains(destination[$0]) })
        guard !removed.isEmpty || !inserted.isEmpty else { return true }
        let reducesMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reducesMotion ? 0 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            beginUpdates()
            removeRows(at: removed, withAnimation: reducesMotion ? [] : [.effectFade, .slideUp])
            insertRows(at: inserted, withAnimation: reducesMotion ? [] : .effectFade)
            endUpdates()
        }
        onContentHeightChanged?()
        return true
    }

    /// 仅对连续分组换位执行原生行移动，保留控件与选择；其它变更由宿主 reload。
    @discardableResult
    func animateReorder(from source: [String], to destination: [String]) -> Bool {
        guard source.count == numberOfRows, let plan = RowReorderPlan(from: source, to: destination) else { return false }
        guard !plan.moves.isEmpty else { return true }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            beginUpdates()
            for move in plan.moves { moveRow(at: move.source, to: move.destination) }
            endUpdates()
        }
        onContentHeightChanged?()
        return true
    }
}
