使用 AppKit 原生表格拖放及独立标题 pasteboard 类型；排序通过 Core 校验、Store 原子持久化与撤销。轮廓沿用已有胶囊几何，增强灰色边框并内缩避免裁切。
排序过渡：采用原生 moveRow，按当前索引逐次调整；220ms easeInEaseOut；reduce motion 置零；集合不一致回退 reload。保留选中标题身份。
本轮最终：原生 NSTableCellView 拖动图像组件（缓存），gap 背景自绘浅灰圆角，160ms easeOut。仅移动连续换位中较小区块，计划 O(n)；项目任务改为字典分组。落下前退出 gap，主队列后续恢复隐藏源行，避免 gap 与 moveRow 临时几何冲突。
