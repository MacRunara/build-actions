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

echo "[macrunara] rn build.sh rev=2026-09-22-npm-verify"
echo "[macrunara] node=$(node --version 2>&1) npm=$(npm --version 2>&1)"
echo "[macrunara] proxy env: http_proxy=${http_proxy:-<unset>} https_proxy=${https_proxy:-<unset>}"

PM="${1:?usage: build.sh <package-manager> <ios-workspace> <ios-scheme> <android-task> <run-tests>}"
IOS_WORKSPACE="${2:-}"
IOS_SCHEME="${3:-}"
ANDROID_TASK="${4:-}"
RUN_TESTS="${5:-true}"

# 后置追加而非前置：确保能找到预装工具即可，不覆盖 PATH 中已有的同名命令
#（单测 mock 依赖此行为；前置会把 runner 自带的真 npm 提到 mock 前面）
export PATH="$PATH:/usr/local/bin"
for d in /Library/Ruby/Gems/*/bin /usr/local/lib/ruby/gems/*/bin "$HOME/.gem/ruby"/*/bin; do
  [ -d "$d" ] && export PATH="$PATH:$d"
done
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"

# 镜像内 ~/.npm/_cacache 可能残留 root 属主文件（镜像制作期曾以 root 执行 npm），
# npm ci 会报 EACCES/EEXIST。把缓存重定向到本次 job 的临时目录，彻底绕开。
export npm_config_cache="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/npm-cache"
mkdir -p "$npm_config_cache"

# 代理链路（squid → 隧道）下 npm 默认的高并发 socket 容易触发连接重置，
# 导致 npm 自身崩溃（Exit handler never called）。限并发 + 重试兜底。
# 客户如需调整可在 workflow env 覆盖同名变量。
export npm_config_maxsockets="${npm_config_maxsockets:-5}"
export npm_config_fetch_retries="${npm_config_fetch_retries:-5}"
export npm_config_fetch_retry_mintimeout="${npm_config_fetch_retry_mintimeout:-10000}"
export npm_config_fetch_retry_maxtimeout="${npm_config_fetch_retry_maxtimeout:-60000}"
echo "[macrunara] maxsockets=$npm_config_maxsockets fetch_retries=$npm_config_fetch_retries"

# --- JS 依赖 ------------------------------------------------------------------
dump_npm_debug_log() {
  echo "::error::npm ci 异常，转储 npm debug 日志末尾："
  ls -t "$npm_config_cache"/_logs/*-debug-0.log 2>/dev/null | head -1 | xargs tail -60 || true
}

case "$PM" in
  npm)
    npm config get proxy https-proxy maxsockets registry 2>/dev/null || true
    set +e
    npm ci --no-audit --no-fund 2>&1 | tee "${RUNNER_TEMP:-/tmp}/npm-ci.log"
    npm_rc=${PIPESTATUS[0]}
    set -e
    # npm 10.x 已知 bug："Exit handler never called" 时可能 exit 0 但并未安装依赖。
    # 因此校验结果而非退出码：报错关键字或 node_modules 缺失都视为失败。
    if [ "$npm_rc" -ne 0 ] || grep -q 'npm error' "${RUNNER_TEMP:-/tmp}/npm-ci.log" || [ ! -d node_modules ]; then
      dump_npm_debug_log
      exit 1
    fi
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

# --- iOS 构建 ------------------------------------------------------------------
if [ -n "$IOS_WORKSPACE" ]; then
  if [ -z "$IOS_SCHEME" ]; then
    echo "::error::ios-scheme is required when ios-workspace is set"
    exit 1
  fi
  if [ "${SIGNING_ENABLED:-0}" = "1" ]; then
    # V1.1-2.1 签名链路：手动签名 archive + 导出 IPA（命令行构建设置优先级最高，
    # 覆盖工程内自动签名）。签名环境由 ios/scripts/setup-signing.sh 经 GITHUB_ENV 注入。
    ARCHIVE_PATH="$PWD/build/${IOS_SCHEME}.xcarchive"
    xcodebuild archive \
      -workspace "$IOS_WORKSPACE" \
      -scheme "$IOS_SCHEME" \
      -configuration Release \
      -sdk iphoneos \
      -archivePath "$ARCHIVE_PATH" \
      CODE_SIGN_STYLE=Manual \
      DEVELOPMENT_TEAM="${TEAM_ID:?SIGNING_ENABLED=1 但缺 TEAM_ID}" \
      PROVISIONING_PROFILE_SPECIFIER="${PROFILE_NAME:?SIGNING_ENABLED=1 但缺 PROFILE_NAME}" \
      CODE_SIGN_IDENTITY="${SIGN_IDENTITY:?SIGNING_ENABLED=1 但缺 SIGN_IDENTITY}"

    # Bundle ID 尽力从 pbxproj 提取，提取不到省略 provisioningProfiles 键
    BUNDLE_ID=""
    PBXPROJ="${IOS_WORKSPACE%.xcworkspace}.xcodeproj/project.pbxproj"
    if [ -f "$PBXPROJ" ]; then
      BUNDLE_ID=$(sed -nE 's/.*PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);.*/\1/p' "$PBXPROJ" | head -1 | tr -d ' ')
      case "$BUNDLE_ID" in *'$'*) BUNDLE_ID="" ;; esac
    fi

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$SCRIPT_DIR/../../ios/scripts/gen-export-options.sh" \
      "$PWD/exportOptions.plist" "${EXPORT_METHOD:-ad-hoc}" "$TEAM_ID" "$PROFILE_NAME" "$BUNDLE_ID"
    xcodebuild -exportArchive \
      -archivePath "$ARCHIVE_PATH" \
      -exportPath "$PWD/build/Exported" \
      -exportOptionsPlist "$PWD/exportOptions.plist"
  else
    # 免签名：iOS 用模拟器目标构建，无需签名
    xcodebuild build \
      -workspace "$IOS_WORKSPACE" \
      -scheme "$IOS_SCHEME" \
      -configuration Debug \
      -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath build/DerivedData
  fi
fi

# --- Android 构建（可选） ------------------------------------------------------
if [ -n "$ANDROID_TASK" ]; then
  # Gradle/JVM 不读 http_proxy/https_proxy 环境变量；节点走代理时
  # 必须转成 JVM 系统属性，否则 Maven 依赖直连被掐（TLS handshake terminated）。
  proxy="${https_proxy:-${http_proxy:-}}"
  if [ -n "$proxy" ]; then
    hostport="${proxy#*://}"; hostport="${hostport#*@}"; hostport="${hostport%/}"
    host="${hostport%%:*}"; port="${hostport##*:}"
    if [ -n "$host" ] && [ -n "$port" ] && [ "$port" != "$hostport" ]; then
      export GRADLE_OPTS="${GRADLE_OPTS:-} -Dhttp.proxyHost=$host -Dhttp.proxyPort=$port -Dhttps.proxyHost=$host -Dhttps.proxyPort=$port"
      echo "==> GRADLE_OPTS proxy -> $host:$port (from env)"
    fi
  fi
  # AGP 的 JdkImageTransform 与 Java 26 的 jlink 不兼容：JAVA_HOME 钉到 LTS JDK。
  # 外层设 MACRUNARA_GRADLE_JDK=off 可关闭。
  if [ "${MACRUNARA_GRADLE_JDK:-on}" != "off" ]; then
    jh="${MACRUNARA_JAVA_HOME_BIN:-/usr/libexec/java_home}"
    for v in 17 21; do
      home=$("$jh" -v "$v" 2>/dev/null) || continue
      if [ -n "$home" ]; then
        export JAVA_HOME="$home"
        echo "==> JAVA_HOME -> $home (pin LTS JDK for Gradle/AGP)"
        break
      fi
    done
  fi
  (cd android && chmod +x gradlew && ./gradlew "$ANDROID_TASK" --no-daemon)
fi

echo "==> react-native build done (pm=$PM ios=${IOS_WORKSPACE:-skip} android=${ANDROID_TASK:-skip})"
