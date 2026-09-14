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

# Gradle/JVM 不读 http_proxy/https_proxy 环境变量；节点走代理时
# 必须转成 JVM 系统属性，否则 Maven 依赖直连被掐（TLS handshake terminated）。
setup_gradle_proxy() {
  local proxy="${https_proxy:-${http_proxy:-}}"
  if [ -z "$proxy" ]; then return 0; fi
  local hostport="${proxy#*://}"
  hostport="${hostport#*@}"   # 去掉可能的 user:pass@
  hostport="${hostport%/}"
  local host="${hostport%%:*}"
  local port="${hostport##*:}"
  if [ -z "$host" ] || [ -z "$port" ] || [ "$port" = "$hostport" ]; then return 0; fi
  export GRADLE_OPTS="${GRADLE_OPTS:-} -Dhttp.proxyHost=$host -Dhttp.proxyPort=$port -Dhttps.proxyHost=$host -Dhttps.proxyPort=$port"
  echo "==> GRADLE_OPTS proxy -> $host:$port (from env)"
}
setup_gradle_proxy

# AGP 的 JdkImageTransform 与 Java 26 的 jlink 不兼容（Gradle 默认捡最新 JDK）。
# 镜像内装有 Homebrew JDK 17/21：跑 Gradle 前把 JAVA_HOME 钉到 LTS。
# 外层设 MACRUNARA_GRADLE_JDK=off 可关闭该行为（如客户项目需要更高版本 JDK）。
setup_gradle_jdk() {
  if [ "${MACRUNARA_GRADLE_JDK:-on}" = "off" ]; then return 0; fi
  local jh="${MACRUNARA_JAVA_HOME_BIN:-/usr/libexec/java_home}"
  local v home
  for v in 17 21; do
    home=$("$jh" -v "$v" 2>/dev/null) || continue
    if [ -n "$home" ]; then
      export JAVA_HOME="$home"
      echo "==> JAVA_HOME -> $home (pin LTS JDK for Gradle/AGP)"
      return 0
    fi
  done
  return 0
}
setup_gradle_jdk

# 可选：国内节点访问 pub.dev 需过代理且易抖动（TLS 握手随机失败）。
# job env 设 MACRUNARA_PUB_MIRROR=cn 即切 Flutter 国内镜像直连；
# 默认不启用，避免海外节点/已有自定义镜像的客户被静默改源。
if [ "${MACRUNARA_PUB_MIRROR:-}" = "cn" ]; then
  export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
  export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
  echo "==> pub mirror -> $PUB_HOSTED_URL (MACRUNARA_PUB_MIRROR=cn)"
fi

flutter --version
flutter pub get

if [ "$RUN_TESTS" = "true" ]; then
  flutter analyze
  flutter test
fi

build_ios() {
  # 免签名 CI 场景统一用 flutter build ios：
  # `flutter build ipa --no-codesign` 会因无法签名而跳过 IPA 导出（编译成功但无产物），
  # build ios 则稳定产出 build/ios/iphoneos/Runner.app，可作为 artifact 验证。
  flutter build ios "--$MODE" --no-codesign
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
