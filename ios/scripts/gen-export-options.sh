#!/usr/bin/env bash
# =============================================================================
# gen-export-options.sh — 生成 xcodebuild -exportArchive 用的 exportOptions.plist
#
# 供 ios / flutter / react-native 三个 action 共用（V1.1-2.1）：
#   bash gen-export-options.sh <out_path> <method> <team_id> <profile_name> [bundle_id]
#
# 位置参数：
#   $1 out_path      输出 plist 路径
#   $2 method        development | ad-hoc | app-store（EXPORT_METHOD）
#   $3 team_id       Apple Developer Team ID（可空，空则省略 teamID 键）
#   $4 profile_name  描述文件名（可空）
#   $5 bundle_id     App Bundle ID（可空；与 profile_name 同时非空才生成
#                    provisioningProfiles 映射，否则省略由 xcodebuild 自动匹配）
#
# 仅当环境变量 SIGNING_ENABLED=1 时写入手动签名键（signingStyle/teamID/
# provisioningProfiles）；否则只写 method（保持历史免签名行为）。
# =============================================================================
set -euo pipefail

OUT="${1:?usage: gen-export-options.sh <out_path> <method> <team_id> <profile_name> [bundle_id]}"
METHOD="${2:-development}"
TEAM_ID="${3:-}"
PROFILE_NAME="${4:-}"
BUNDLE_ID="${5:-}"
SIGNING="${SIGNING_ENABLED:-0}"

{
  cat <<'HEADER'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
HEADER
  echo "  <key>method</key>"
  echo "  <string>$METHOD</string>"
  if [ "$SIGNING" = "1" ]; then
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
} > "$OUT"
