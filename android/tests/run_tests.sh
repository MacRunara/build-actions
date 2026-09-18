#!/usr/bin/env bash
# =============================================================================
# android/tests/run_tests.sh — Android action 脚本单元测试（零依赖 bash 套件）
#
# 原理：在用例目录放置 mock gradlew（记录参数到 $MOCK_LOG 并生成假 APK），
# 调用 scripts/build.sh 断言 task 拼接与执行行为。
#
# 本地运行：
#   cd build-actions
#   bash android/tests/run_tests.sh
# =============================================================================
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "$TESTS_DIR/.." && pwd)"
BUILD_SH="$ACTION_DIR/scripts/build.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1（期望 [$2]，实际 [$3]）"; fi
}
assert_file_exists() {
  if [ -f "$2" ]; then pass "$1"; else fail "$1（文件不存在: $2）"; fi
}
assert_contains() {
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1（$2 中未找到: $3）"; fi
}
assert_not_contains() {
  if [ ! -f "$2" ] || ! grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1（$2 中不应出现: $3）"; fi
}

if [ ! -f "$BUILD_SH" ]; then
  echo "FATAL - 脚本不存在: $BUILD_SH"
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# =============================================================================
# 用例 1：task 不含冒号 + module=app → 拼成 :app:assembleDebug
# =============================================================================
CASE="$WORK/case1"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
cat > gradlew <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_LOG"
# 从 :module:task 解析 module 与 task，生成假 APK
TASK="$1"
MODULE_PART=$(echo "$TASK" | cut -d: -f2)
TASK_PART=$(echo "$TASK" | cut -d: -f3)
mkdir -p "$MODULE_PART/build/outputs/apk/debug"
touch "$MODULE_PART/build/outputs/apk/debug/${MODULE_PART}-debug.apk"
echo "mock gradlew: ran $TASK_PART on $MODULE_PART"
MOCK
chmod +x gradlew

bash "$BUILD_SH" "assembleDebug" "app" >out.log 2>&1
rc=$?
assert_eq "用例1: 退出码为 0" "0" "$rc"
assert_contains "用例1: task 拼成 :app:assembleDebug" "$MOCK_LOG" ":app:assembleDebug --no-daemon"
assert_file_exists "用例1: 生成 app/build/outputs/apk/debug/app-debug.apk" "app/build/outputs/apk/debug/app-debug.apk"

# =============================================================================
# 用例 2：task 已含冒号（全限定）→ 原样传递，不再拼 module
# =============================================================================
CASE="$WORK/case2"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
cat > gradlew <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_LOG"
MOCK
chmod +x gradlew

bash "$BUILD_SH" ":library:bundleRelease" "app" >out.log 2>&1
rc=$?
assert_eq "用例2: 退出码为 0" "0" "$rc"
assert_contains "用例2: 全限定 task 原样传递" "$MOCK_LOG" ":library:bundleRelease --no-daemon"

# =============================================================================
# 用例 3：module 留空 → task 原样执行（不拼模块前缀）
# =============================================================================
CASE="$WORK/case3"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
cat > gradlew <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_LOG"
MOCK
chmod +x gradlew

bash "$BUILD_SH" "assembleDebug" "" >out.log 2>&1
rc=$?
assert_eq "用例3: 退出码为 0" "0" "$rc"
assert_contains "用例3: module 为空时 task 原样执行" "$MOCK_LOG" "assembleDebug --no-daemon"

# =============================================================================
# 用例 4：ANDROID_HOME 缺省时自动指向 ~/Library/Android/sdk
# =============================================================================
CASE="$WORK/case4"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
cat > gradlew <<'MOCK'
#!/usr/bin/env bash
echo "ANDROID_HOME=$ANDROID_HOME" >> "$MOCK_LOG"
MOCK
chmod +x gradlew

unset ANDROID_HOME || true
bash "$BUILD_SH" "help" "" >out.log 2>&1
rc=$?
assert_eq "用例4: 退出码为 0" "0" "$rc"
assert_contains "用例4: ANDROID_HOME 缺省指向预装路径" "$MOCK_LOG" "ANDROID_HOME=$HOME/Library/Android/sdk"

# =============================================================================
# 用例 5：设置 https_proxy 时向 Gradle 注入 JVM 代理参数（JVM 不读 *_proxy 环境变量）
# =============================================================================
CASE="$WORK/case5"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
cat > gradlew <<'MOCK'
#!/usr/bin/env bash
echo "$@ | GRADLE_OPTS=${GRADLE_OPTS:-}" >> "$MOCK_LOG"
MOCK
chmod +x gradlew

https_proxy=http://172.16.0.81:7890 bash "$BUILD_SH" "assembleDebug" "app" >out.log 2>&1
rc=$?
assert_eq "用例5: 退出码为 0" "0" "$rc"
assert_contains "用例5: GRADLE_OPTS 注入 http 代理" "$MOCK_LOG" "-Dhttp.proxyHost=172.16.0.81 -Dhttp.proxyPort=7890"
assert_contains "用例5: GRADLE_OPTS 注入 https 代理" "$MOCK_LOG" "-Dhttps.proxyHost=172.16.0.81 -Dhttps.proxyPort=7890"

# =============================================================================
# 用例 6：存在 JDK 17 时 JAVA_HOME 钉到 LTS（AGP JdkImageTransform 与 Java 26 不兼容）
# =============================================================================
CASE="$WORK/case6"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
cat > gradlew <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_LOG"
MOCK
chmod +x gradlew
cat > java_home_mock <<'M'
#!/usr/bin/env bash
if [ "${1:-}" = "-v" ] && [ "${2:-}" = "17" ]; then echo "/fake/jdk17/Home"; exit 0; fi
exit 1
M
chmod +x java_home_mock

MACRUNARA_JAVA_HOME_BIN="$CASE/java_home_mock" bash "$BUILD_SH" "assembleDebug" "app" >out.log 2>&1
rc=$?
assert_eq "用例6: 退出码为 0" "0" "$rc"
assert_contains "用例6: JAVA_HOME 钉到 JDK17" "out.log" "JAVA_HOME -> /fake/jdk17/Home"
assert_contains "用例6: 仍执行 gradlew" "$MOCK_LOG" ":app:assembleDebug --no-daemon"

SETUP_SIGNING_SH="$ACTION_DIR/scripts/setup-android-signing.sh"

# =============================================================================
# 用例 7：setup-android-signing.sh happy path —— keystore 落盘 + init.d 注入脚本
# =============================================================================
CASE="$WORK/case7"; mkdir -p "$CASE/gradle-home"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export GRADLE_USER_HOME="$CASE/gradle-home"
export RUNNER_TEMP="$CASE/rt"
KEYSTORE_B64="$(printf 'fake-keystore-bytes' | base64 -w0)"

bash "$SETUP_SIGNING_SH" "$KEYSTORE_B64" "store-pw" "my-alias" "key-pw" "$CASE/signing.env" >out.log 2>&1
rc=$?
assert_eq "用例7: 退出码为 0" "0" "$rc"
assert_file_exists "用例7: keystore 落盘" "$CASE/rt/macrunara-signing/keystore.jks"
assert_file_exists "用例7: init.d 注入脚本生成" "$CASE/gradle-home/init.d/macrunara-signing.gradle"
assert_contains "用例7: init 脚本有 env 缺失 no-op 保护" "$CASE/gradle-home/init.d/macrunara-signing.gradle" "MACRUNARA_KEYSTORE_PATH"
assert_contains "用例7: init 脚本注入 macrunaraCi signingConfig" "$CASE/gradle-home/init.d/macrunara-signing.gradle" "macrunaraCi"
assert_contains "用例7: init 脚本只覆盖 release 系 buildType" "$CASE/gradle-home/init.d/macrunara-signing.gradle" "contains('release')"
assert_contains "用例7: 评估期注入（gradle.allprojects）" "$CASE/gradle-home/init.d/macrunara-signing.gradle" "gradle.allprojects"
assert_not_contains "用例7: 不用 projectsEvaluated（AGP 固化 DSL 后太晚会报错）" "$CASE/gradle-home/init.d/macrunara-signing.gradle" "projectsEvaluated {"
assert_contains "用例7: env 文件含 keystore 路径" "$CASE/signing.env" "MACRUNARA_KEYSTORE_PATH=$CASE/rt/macrunara-signing/keystore.jks"
assert_contains "用例7: env 文件含 alias" "$CASE/signing.env" "MACRUNARA_KEY_ALIAS=my-alias"
assert_contains "用例7: 启用标记" "$CASE/signing.env" "ANDROID_SIGNING_ENABLED=1"
assert_not_contains "用例7: 日志不泄露 store 密码" "$CASE/out.log" "store-pw"
assert_not_contains "用例7: 日志不泄露 key 密码" "$CASE/out.log" "key-pw"
assert_not_contains "用例7: 日志不泄露 keystore base64" "$CASE/out.log" "$KEYSTORE_B64"
unset GRADLE_USER_HOME RUNNER_TEMP

# =============================================================================
# 用例 8：setup-android-signing.sh 空 keystore → 跳过；缺密码 → 报错
# =============================================================================
CASE="$WORK/case8"; mkdir -p "$CASE/gradle-home"; cd "$CASE"
export GRADLE_USER_HOME="$CASE/gradle-home"

bash "$SETUP_SIGNING_SH" "" "" "" "" "$CASE/signing.env" >out.log 2>&1
rc=$?
assert_eq "用例8: 空 keystore 退出码为 0（跳过）" "0" "$rc"
assert_eq "用例8: 不生成 init 脚本" "0" "$([ -f "$CASE/gradle-home/init.d/macrunara-signing.gradle" ] && echo 1 || echo 0)"

out="$(bash "$SETUP_SIGNING_SH" "a2V5c3RvcmU=" "" "alias" "" "$CASE/x.env" 2>&1 || true)"
if echo "$out" | grep -qF "::error::"; then
  pass "用例8: 缺密码时报 ::error::"
else
  fail "用例8: 缺密码未报错（实际输出: $out）"
fi
unset GRADLE_USER_HOME

# --- 汇总 ---------------------------------------------------------------------
echo ""
echo "==============================================="
echo "通过: $PASS  失败: $FAIL"
echo "==============================================="
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
echo "全部用例通过"
