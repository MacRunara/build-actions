#!/usr/bin/env bash
# =============================================================================
# export-archive.sh — 若构建目录中存在 .xcarchive，则导出 IPA
#
# 由 ios/action.yml 的 "Export archive if present" 步骤调用：
#   bash "${{ github.action_path }}/scripts/export-archive.sh"
#
# 行为说明：
# - 在 Runner 工作目录（当前目录）3 层深度内搜索第一个 .xcarchive；
# - 未找到：打印提示并以退出码 0 结束（不视为失败）；
# - 找到：生成 development 方式的 exportOptions.plist 并执行
#   xcodebuild -exportArchive；导出失败仅输出 ::warning::，不中断 workflow。
# =============================================================================
set -euo pipefail

ARCHIVE=$(find . -maxdepth 3 -name "*.xcarchive" -print -quit || true)
if [ -z "$ARCHIVE" ]; then
  echo "No .xcarchive found; skipping exportArchive"
  exit 0
fi

echo "Found archive: $ARCHIVE"
cat > exportOptions.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key>
  <string>development</string>
</dict>
</plist>
EOF

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath ./build/Exported \
  -exportOptionsPlist exportOptions.plist || echo "::warning::exportArchive failed (check signing/export options)"
