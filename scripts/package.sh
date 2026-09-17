#!/bin/bash
set -euo pipefail
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
configuration="${1:-release}"
if [[ "$configuration" != release && "$configuration" != debug ]]; then
  echo "用法：bash scripts/package.sh [release|debug]" >&2
  exit 2
fi
swift build --configuration "$configuration"
binary_dir="$(swift build --configuration "$configuration" --show-bin-path)"
app_path="$project_root/build/拾事.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$binary_dir/Shishi" "$app_path/Contents/MacOS/Shishi"
# 正式应用去除调试符号；debug 包保留符号用于排查。
if [[ "$configuration" == release ]]; then
  xcrun strip -S "$app_path/Contents/MacOS/Shishi"
fi
cp resources/Info.plist "$app_path/Contents/Info.plist"
cp resources/help.html "$app_path/Contents/Resources/help.html"
# 编译品牌强调色（#1D60C4），让按钮、复选框等系统控件也使用同一蓝色；只有命令行工具时跳过。
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool resources/Assets.xcassets --compile "$app_path/Contents/Resources" --platform macosx \
    --minimum-deployment-target 13.0 --output-partial-info-plist "$project_root/build/assets-info.plist" >/dev/null
else
  echo "未找到 actool，系统控件强调色保持系统默认" >&2
fi
swift scripts/icon.swift "$project_root/build"
iconutil -c icns "$project_root/build/Shishi.iconset" -o "$app_path/Contents/Resources/Shishi.icns"
codesign --force --sign - "$app_path"
codesign --verify --strict "$app_path"
echo "$app_path"
