# 列表焦点外框

build/autonomous，用户截图为目标v1：移除包围整张项目列表的蓝色焦点环，保留行选择和键盘行为。只设置NSTableView.focusRingType为none，不取消first responder资格，不改输入框/按钮焦点。纯AppKit，一轮self-review，不修改真实库。
