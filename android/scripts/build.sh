#!/usr/bin/env bash
# =============================================================================
# android/scripts/build.sh — Gradle Wrapper 构建
#
# 由 android/action.yml 的 "Gradle build" 步骤调用：
#   bash "${{ github.action_path }}/scripts/build.sh" \
#     "${{ inputs.task }}" "${{ inputs.module }}"
#
# 位置参数：
#   $1 task    Gradle 任务（assembleDebug / bundleRelease / :app:assembleDebug）
#   $2 module  模块名；task 不含冒号且 module 非空时拼成 :<module>:<task>
#
# 说明：
# - ANDROID_HOME 缺省指向节点预装路径 ~/Library/Android/sdk；
# - --no-daemon：CI 一次性构建，不保留守护进程。
# =============================================================================
set -euo pipefail

TASK="${1:?usage: build.sh <task> <module>}"
MODULE="${2:-app}"

export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [ -d "$ANDROID_HOME/platform-tools" ]; then
  export PATH="$ANDROID_HOME/platform-tools:$PATH"
fi

# task 不含冒号且 module 非空 → 拼成 :module:task（Gradle 全限定路径）
FULL_TASK="$TASK"
if [[ "$TASK" != *:* ]] && [ -n "$MODULE" ]; then
  FULL_TASK=":${MODULE}:${TASK}"
fi

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
# 外层设 MACRUNARA_GRADLE_JDK=off 可关闭该行为。
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

# maven 中央仓/插件门户镜像注入（出口带宽治理）：aliyun 镜像经 squid
# domestic_mirrors 直连不出境；外层设 MACRUNARA_MAVEN_MIRROR=off 关闭。
bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/setup-maven-mirrors.sh"

chmod +x ./gradlew
echo "==> ./gradlew $FULL_TASK --no-daemon"
./gradlew "$FULL_TASK" --no-daemon
