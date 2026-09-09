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

chmod +x ./gradlew
echo "==> ./gradlew $FULL_TASK --no-daemon"
./gradlew "$FULL_TASK" --no-daemon
