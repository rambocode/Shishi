import AppKit

/// 外层文档顶部对齐；高度约束只扩展文档，不参与父窗口的最小内容尺寸。
@MainActor final class ListScrollDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// 表格的 row 索引和原生可见区域保持不变，文档高度取自 AppKit 的行几何。
@MainActor extension ListTableView {
    var fullContentHeight: CGFloat {
        guard numberOfRows > 0 else { return 0 }
        return ceil(rect(ofRow: numberOfRows - 1).maxY)
    }

    /// 先完成外层文档布局，再用视图坐标转换定位，避免将表格坐标误作 clip 坐标。
    func revealRowInDocument(_ row: Int) {
        guard row >= 0, row < numberOfRows else { return }
        enclosingScrollView?.superview?.layoutSubtreeIfNeeded()
        let rect = rect(ofRow: row)
        // 高卡片超过视口时优先露出标题；后续输入控件使用原生 scrollRectToVisible。
        let height = min(rect.height, enclosingScrollView?.contentView.bounds.height ?? rect.height)
        scrollToVisible(NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: height))
    }
}
