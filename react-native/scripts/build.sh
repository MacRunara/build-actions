#!/usr/bin/env bash
# =============================================================================
# react-native/scripts/build.sh — React Native 构建链路
#
# 由 react-native/action.yml 的 "React Native build pipeline" 步骤调用：
#   bash "${{ github.action_path }}/scripts/build.sh" \
#     "${{ inputs.package-manager }}" "${{ inputs.ios-workspace }}" \
#     "${{ inputs.ios-scheme }}" "${{ inputs.android-task }}" "${{ inputs.run-tests }}"
#
# 位置参数：
#   $1 package-manager  npm | yarn
#   $2 ios-workspace    ios/MyApp.xcworkspace（空 = 跳过 iOS 构建）
#   $3 ios-scheme       scheme 名（workspace 非空时必填）
#   $4 android-task     如 assembleDebug（空 = 跳过 Android 构建）
#   $5 run-tests        true | false（true = 构建前先跑 JS 测试）
#
# 说明：
# - PATH 显式补 /usr/local/bin（node）与系统 gem bin 目录（pod），
#   不依赖登录 shell；
# - iOS 用模拟器目标构建，无需签名；
# - Android 在 android/ 子目录内执行 gradlew。
# =============================================================================
set -euo pipefail

PM="${1:?usage: build.sh <package-manager> <ios-workspace> <ios-scheme> <android-task> <run-tests>}"
IOS_WORKSPACE="${2:-}"
IOS_SCHEME="${3:-}"
ANDROID_TASK="${4:-}"
RUN_TESTS="${5:-true}"

export PATH="/usr/local/bin:$PATH"
for d in /Library/Ruby/Gems/*/bin /usr/local/lib/ruby/gems/*/bin "$HOME/.gem/ruby"/*/bin; do
  [ -d "$d" ] && export PATH="$d:$PATH"
done
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

# --- JS 依赖 ------------------------------------------------------------------
case "$PM" in
  npm)
    npm ci
    ;;
  yarn)
    yarn install --frozen-lockfile
    ;;
  *)
    echo "::error::package-manager must be npm|yarn, got: $PM"
    exit 1
    ;;
esac

# --- iOS 原生依赖（有 Podfile 才装） -------------------------------------------
if [ -f ios/Podfile ]; then
  (cd ios && pod install)
else
  echo "::notice::ios/Podfile not found, skipping pod install"
fi

# --- JS 测试 ------------------------------------------------------------------
if [ "$RUN_TESTS" = "true" ]; then
  case "$PM" in
    npm)  npm test ;;
    yarn) yarn test ;;
  esac
fi

# --- iOS 模拟器构建（无需签名） ------------------------------------------------
if [ -n "$IOS_WORKSPACE" ]; then
  if [ -z "$IOS_SCHEME" ]; then
    echo "::error::ios-scheme is required when ios-workspace is set"
    exit 1
  fi
  xcodebuild build \
    -workspace "$IOS_WORKSPACE" \
    -scheme "$IOS_SCHEME" \
    -configuration Debug \
    -destination 'generic/platform=iOS Simulator' \
    -derivedDataPath build/DerivedData
fi

# --- Android 构建（可选） ------------------------------------------------------
if [ -n "$ANDROID_TASK" ]; then
  (cd android && chmod +x gradlew && ./gradlew "$ANDROID_TASK" --no-daemon)
fi

echo "==> react-native build done (pm=$PM ios=${IOS_WORKSPACE:-skip} android=${ANDROID_TASK:-skip})"
