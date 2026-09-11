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

# CI 环境无签名证书：显式关闭代码签名。
# iphoneos SDK 默认要求 development team，否则报
# "Signing for "X" requires a development team"（exit 65）。
# 后续如需签名分发（TestFlight/蒲公英），再加 signing 相关 inputs 扩展。
xcodebuild \
  "${PROJECT_ARGS[@]}" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -sdk "$SDK" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY= \
  EXPANDED_CODE_SIGN_IDENTITY=
