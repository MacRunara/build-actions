#!/usr/bin/env bash
# =============================================================================
# build.sh — 在 Macrunara Mac Runner 上执行 xcodebuild 构建
#
# 由 ios/action.yml 的 "Build Xcode project" 步骤调用：
#   bash "${{ github.action_path }}/scripts/build.sh" \
#     "${{ inputs.scheme }}" "${{ inputs.project }}" \
#     "${{ inputs.configuration }}" "${{ inputs.sdk }}"
#
# 位置参数：
#   $1 scheme        必填，Xcode scheme
#   $2 project       可选，.xcodeproj/.xcworkspace 路径（空字符串表示不传 -project）
#   $3 configuration 构建配置（Release/Debug）
#   $4 sdk           目标 SDK（iphoneos/macosx）
# =============================================================================
set -euo pipefail

SCHEME="${1:?usage: build.sh <scheme> <project> <configuration> <sdk>}"
PROJECT="${2:-}"
CONFIGURATION="${3:-Release}"
SDK="${4:-iphoneos}"

# 仅当 project 非空时才追加 -project 参数（workspace/单工程场景可省略）
PROJECT_ARGS=()
if [ -n "$PROJECT" ]; then
  PROJECT_ARGS+=("-project" "$PROJECT")
fi

# CI 环境无签名证书时：显式关闭代码签名。
# iphoneos SDK 默认要求 development team，否则报
# "Signing for "X" requires a development team"（exit 65）。
#
# V1.1-2.1：SIGNING_ENABLED=1（由 setup-signing.sh 写入环境）时切换为
# 手动签名 archive 模式，产物为 .xcarchive，由 export-archive.sh 导出 IPA。
#
# SYMROOT 必须显式指定：默认产物落在 ~/Library/Developer/Xcode/DerivedData/<app>-<hash>/，
# action.yml 的默认 artifact_path（build/Release-iphoneos）将永远匹配不到，
# upload-artifact 静默 "No files found"（2026-09-16 实测踩坑）。
SYMROOT_DIR="${GITHUB_WORKSPACE:-$PWD}/build"

if [ "${SIGNING_ENABLED:-0}" = "1" ]; then
  # 手动签名 archive：证书在临时 keychain（setup-signing.sh 已装入搜索列表）
  ARCHIVE_PATH="$SYMROOT_DIR/${SCHEME}.xcarchive"
  xcodebuild archive \
    "${PROJECT_ARGS[@]}" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk "$SDK" \
    SYMROOT="$SYMROOT_DIR" \
    -archivePath "$ARCHIVE_PATH" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="${TEAM_ID:?SIGNING_ENABLED=1 但缺 TEAM_ID（setup-signing.sh 未执行？）}" \
    PROVISIONING_PROFILE_SPECIFIER="${PROFILE_NAME:?SIGNING_ENABLED=1 但缺 PROFILE_NAME}" \
    CODE_SIGN_IDENTITY="${SIGN_IDENTITY:?SIGNING_ENABLED=1 但缺 SIGN_IDENTITY}"
else
  xcodebuild \
    "${PROJECT_ARGS[@]}" \
    -scheme "$SCHEME" \
    -configuration "$CONFIGURATION" \
    -sdk "$SDK" \
    SYMROOT="$SYMROOT_DIR" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    EXPANDED_CODE_SIGN_IDENTITY=
fi
