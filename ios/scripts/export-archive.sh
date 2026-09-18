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

# V1.1-2.1：导出方式与手动签名参数来自环境变量（setup-signing.sh 经 GITHUB_ENV 注入）。
# 无签名环境时保持历史行为：method=development、无签名键。
EXPORT_METHOD="${EXPORT_METHOD:-development}"
TEAM_ID="${TEAM_ID:-}"
PROFILE_NAME="${PROFILE_NAME:-}"
SIGNING_ENABLED="${SIGNING_ENABLED:-0}"

# Bundle ID 用于手动签名的 provisioningProfiles 映射；从归档 Info.plist 尽力提取，
# 提取不到就省略该键（xcodebuild 会按 profile 自动匹配）。
BUNDLE_ID="${BUNDLE_ID:-}"
PLISTBUDDY="${PLISTBUDDY_BIN:-/usr/libexec/PlistBuddy}"
if [ -z "$BUNDLE_ID" ] && [ -x "$PLISTBUDDY" ]; then
  BUNDLE_ID=$("$PLISTBUDDY" -c "Print :ApplicationProperties:CFBundleIdentifier" "$ARCHIVE/Info.plist" 2>/dev/null || true)
fi

{
  cat <<'HEADER'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
HEADER
  echo "  <key>method</key>"
  echo "  <string>$EXPORT_METHOD</string>"
  if [ "$SIGNING_ENABLED" = "1" ]; then
    echo "  <key>signingStyle</key>"
    echo "  <string>manual</string>"
    if [ -n "$TEAM_ID" ]; then
      echo "  <key>teamID</key>"
      echo "  <string>$TEAM_ID</string>"
    fi
    if [ -n "$BUNDLE_ID" ] && [ -n "$PROFILE_NAME" ]; then
      echo "  <key>provisioningProfiles</key>"
      echo "  <dict>"
      echo "    <key>$BUNDLE_ID</key>"
      echo "    <string>$PROFILE_NAME</string>"
      echo "  </dict>"
    fi
  fi
  echo "</dict>"
  echo "</plist>"
} > exportOptions.plist

xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath ./build/Exported \
  -exportOptionsPlist exportOptions.plist || echo "::warning::exportArchive failed (check signing/export options)"
