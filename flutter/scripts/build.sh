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

# 出口带宽治理（2026-09-22）：舰队在国内、香港出口带宽是瓶颈，
# 默认切 Flutter 国内镜像直连（不过代理，流量不出境）。
# 海外自建 runner 客户可设 MACRUNARA_PUB_MIRROR=official 改回 pub.dev。
if [ "${MACRUNARA_PUB_MIRROR:-cn}" = "cn" ]; then
  export PUB_HOSTED_URL="${PUB_HOSTED_URL:-https://pub.flutter-io.cn}"
  export FLUTTER_STORAGE_BASE_URL="${FLUTTER_STORAGE_BASE_URL:-https://storage.flutter-io.cn}"
  echo "==> pub mirror -> $PUB_HOSTED_URL (MACRUNARA_PUB_MIRROR=cn, default)"
fi

flutter --version
flutter pub get

if [ "$RUN_TESTS" = "true" ]; then
  flutter analyze
  flutter test
fi

build_ios() {
  if [ "${SIGNING_ENABLED:-0}" = "1" ]; then
    build_ios_signed
    return 0
  fi
  # 免签名 CI 场景统一用 flutter build ios：
  # `flutter build ipa --no-codesign` 会因无法签名而跳过 IPA 导出（编译成功但无产物），
  # build ios 则稳定产出 build/ios/iphoneos/Runner.app，可作为 artifact 验证。
  flutter build ios "--$MODE" --no-codesign
}

# V1.1-2.1 签名链路：flutter build ipa 无法透传 xcodebuild 构建设置，
# 拆成两步——① flutter build ios --no-codesign 完成引擎编译与 pod 准备；
# ② 手动 archive（命令行构建设置优先级最高，覆盖工程内自动签名）+ 导出 IPA。
# 签名环境由 ios/scripts/setup-signing.sh 经 GITHUB_ENV 注入
#（SIGNING_ENABLED/TEAM_ID/PROFILE_NAME/SIGN_IDENTITY/EXPORT_METHOD）。
build_ios_signed() {
  if [ "$MODE" != "release" ]; then
    echo "::warning::签名 IPA 仅支持 release，build-mode=$MODE 已强制按 release 签名构建"
  fi
  flutter build ios --release --no-codesign

  local ws="${MACRUNARA_IOS_WORKSPACE:-ios/Runner.xcworkspace}"
  local scheme="${MACRUNARA_IOS_SCHEME:-Runner}"
  local archive="$PWD/build/ios/${scheme}.xcarchive"

  xcodebuild archive \
    -workspace "$ws" \
    -scheme "$scheme" \
    -configuration Release \
    -sdk iphoneos \
    -archivePath "$archive" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="${TEAM_ID:?SIGNING_ENABLED=1 但缺 TEAM_ID}" \
    PROVISIONING_PROFILE_SPECIFIER="${PROFILE_NAME:?SIGNING_ENABLED=1 但缺 PROFILE_NAME}" \
    CODE_SIGN_IDENTITY="${SIGN_IDENTITY:?SIGNING_ENABLED=1 但缺 SIGN_IDENTITY}"

  # Bundle ID 尽力从 pbxproj 提取（可能含 $(VAR) 变量，提取不到就省略
  # provisioningProfiles 键，交给 xcodebuild 按描述文件自动匹配）
  local bundle_id=""
  local pbxproj="ios/Runner.xcodeproj/project.pbxproj"
  if [ -f "$pbxproj" ]; then
    bundle_id=$(sed -nE 's/.*PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);.*/\1/p' "$pbxproj" | head -1 | tr -d ' ')
    case "$bundle_id" in *'$'*) bundle_id="" ;; esac
  fi

  local script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  bash "$script_dir/../../ios/scripts/gen-export-options.sh" \
    "$PWD/exportOptions.plist" "${EXPORT_METHOD:-ad-hoc}" "$TEAM_ID" "$PROFILE_NAME" "$bundle_id"

  xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportPath "$PWD/build/ios/Exported" \
    -exportOptionsPlist "$PWD/exportOptions.plist"
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
