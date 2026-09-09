#!/usr/bin/env bash
# =============================================================================
# flutter/scripts/build.sh — Flutter 构建链路
#
# 由 flutter/action.yml 的 "Flutter build pipeline" 步骤调用：
#   bash "${{ github.action_path }}/scripts/build.sh" \
#     "${{ inputs.platform }}" "${{ inputs.build-mode }}" "${{ inputs.run-tests }}"
#
# 位置参数：
#   $1 platform   ios | android | all
#   $2 build-mode debug | release
#   $3 run-tests  true | false（true = 构建前先 analyze + test）
#
# 说明：
# - 预装 Flutter 在 ~/flutter/bin，脚本内显式补 PATH，不依赖登录 shell；
# - iOS 产物无签名（--no-codesign），CI 仅验证编译链路；
# - debug 模式下 iOS 用 `flutter build ios`（ipa 仅支持 release/profile）。
# =============================================================================
set -euo pipefail

PLATFORM="${1:?usage: build.sh <platform> <build-mode> <run-tests>}"
MODE="${2:-debug}"
RUN_TESTS="${3:-true}"

export PATH="$PATH:$HOME/flutter/bin"
git config --global --add safe.directory "$HOME/flutter" 2>/dev/null || true

flutter --version
flutter pub get

if [ "$RUN_TESTS" = "true" ]; then
  flutter analyze
  flutter test
fi

build_ios() {
  if [ "$MODE" = "release" ]; then
    flutter build ipa --release --no-codesign
  else
    flutter build ios --debug --no-codesign
  fi
}

build_android() {
  flutter build apk "--$MODE"
}

case "$PLATFORM" in
  ios)     build_ios ;;
  android) build_android ;;
  all)     build_ios; build_android ;;
  *)       echo "::error::platform must be ios|android|all, got: $PLATFORM"; exit 1 ;;
esac

echo "==> flutter build done (platform=$PLATFORM mode=$MODE)"
