#!/usr/bin/env bash
# =============================================================================
# flutter/tests/run_tests.sh — Flutter action 脚本单元测试（零依赖 bash 套件）
#
# 原理：mock flutter（记录调用序列到 $MOCK_LOG，build 时生成假 ipa/apk），
# 前置到 PATH 后调用 scripts/build.sh 断言平台/模式组合行为。
#
# 本地运行：
#   cd build-actions
#   bash flutter/tests/run_tests.sh
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
assert_dir_exists() {
  if [ -d "$2" ]; then pass "$1"; else fail "$1（目录不存在: $2）"; fi
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

mkdir -p "$WORK/mock-bin"
cat > "$WORK/mock-bin/flutter" <<'MOCK'
#!/usr/bin/env bash
# Mock flutter：记录每次调用到 $MOCK_LOG；build 子命令生成假产物。
echo "flutter $@ | GRADLE_OPTS=${GRADLE_OPTS:-}" >> "$MOCK_LOG"
if [ "$1" = "build" ]; then
  case "$2" in
    ios)
      mkdir -p build/ios/iphoneos/Runner.app
      ;;
    ipa)
      mkdir -p build/ios/ipa
      touch "build/ios/ipa/Runner.ipa"
      ;;
    apk)
      MODE=debug
      for a in "$@"; do
        case "$a" in --release) MODE=release ;; --profile) MODE=profile ;; esac
      done
      mkdir -p build/app/outputs/flutter-apk
      touch "build/app/outputs/flutter-apk/app-${MODE}.apk"
      ;;
  esac
fi
MOCK
chmod +x "$WORK/mock-bin/flutter"

# =============================================================================
# 用例 1：platform=all + debug + run-tests=true → analyze/test/双端构建全走
# =============================================================================
CASE="$WORK/case1"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$WORK/mock-bin:$PATH"

bash "$BUILD_SH" "all" "debug" "true" >out.log 2>&1
rc=$?
assert_eq "用例1: 退出码为 0" "0" "$rc"
assert_contains "用例1: 执行 pub get" "$MOCK_LOG" "flutter pub get"
assert_contains "用例1: 执行 analyze" "$MOCK_LOG" "flutter analyze"
assert_contains "用例1: 执行 test" "$MOCK_LOG" "flutter test"
assert_contains "用例1: iOS debug 构建（build ios --debug）" "$MOCK_LOG" "flutter build ios --debug --no-codesign"
assert_contains "用例1: Android debug 构建（build apk --debug）" "$MOCK_LOG" "flutter build apk --debug"
assert_dir_exists "用例1: 生成 iOS 产物" "build/ios/iphoneos/Runner.app"
assert_file_exists "用例1: 生成 Android 产物" "build/app/outputs/flutter-apk/app-debug.apk"

# =============================================================================
# 用例 2：platform=ios + release → build ios --release --no-codesign
# （免签名不用 build ipa：--no-codesign 时 flutter 会跳过 IPA 导出，无产物）
# =============================================================================
CASE="$WORK/case2"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$WORK/mock-bin:$PATH"

bash "$BUILD_SH" "ios" "release" "false" >out.log 2>&1
rc=$?
assert_eq "用例2: 退出码为 0" "0" "$rc"
assert_contains "用例2: release 走 build ios" "$MOCK_LOG" "flutter build ios --release --no-codesign"
assert_not_contains "用例2: 不走 build ipa" "$MOCK_LOG" "flutter build ipa"
assert_not_contains "用例2: 不执行 analyze/test" "$MOCK_LOG" "flutter analyze"
assert_not_contains "用例2: 不构建 Android" "$MOCK_LOG" "flutter build apk"
assert_dir_exists "用例2: 生成 iOS 产物" "build/ios/iphoneos/Runner.app"

# =============================================================================
# 用例 3：platform=android + release → 只构建 apk
# =============================================================================
CASE="$WORK/case3"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$WORK/mock-bin:$PATH"

bash "$BUILD_SH" "android" "release" "false" >out.log 2>&1
rc=$?
assert_eq "用例3: 退出码为 0" "0" "$rc"
assert_contains "用例3: 构建 apk --release" "$MOCK_LOG" "flutter build apk --release"
assert_not_contains "用例3: 不构建 iOS" "$MOCK_LOG" "build ios"
assert_not_contains "用例3: 不构建 iOS（ipa）" "$MOCK_LOG" "build ipa"
assert_file_exists "用例3: 生成 app-release.apk" "build/app/outputs/flutter-apk/app-release.apk"

# =============================================================================
# 用例 4：非法 platform → 退出码 1 且报 ::error::
# =============================================================================
CASE="$WORK/case4"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$WORK/mock-bin:$PATH"

out="$(bash "$BUILD_SH" "windows" "debug" "false" 2>&1)"
rc=$?
assert_eq "用例4: 非法 platform 退出码为 1" "1" "$rc"
if echo "$out" | grep -qF "::error::platform must be ios|android|all"; then
  pass "用例4: 输出 ::error:: 提示"
else
  fail "用例4: 缺少 ::error:: 提示（实际输出: $out）"
fi

# =============================================================================
# 用例 5：run-tests=false 时跳过 analyze 和 test，但仍有 pub get
# =============================================================================
CASE="$WORK/case5"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$WORK/mock-bin:$PATH"

bash "$BUILD_SH" "android" "debug" "false" >out.log 2>&1
rc=$?
assert_eq "用例5: 退出码为 0" "0" "$rc"
assert_contains "用例5: 仍执行 pub get" "$MOCK_LOG" "flutter pub get"
assert_not_contains "用例5: 跳过 analyze" "$MOCK_LOG" "flutter analyze"
assert_not_contains "用例5: 跳过 test" "$MOCK_LOG" "flutter test"

# =============================================================================
# 用例 6：设置 https_proxy 时向 Gradle 注入 JVM 代理参数（JVM 不读 *_proxy 环境变量）
# =============================================================================
CASE="$WORK/case6"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$WORK/mock-bin:$PATH"

https_proxy=http://172.16.0.81:7890 bash "$BUILD_SH" android release false >out.log 2>&1
rc=$?
assert_eq "用例6: 退出码为 0" "0" "$rc"
assert_contains "用例6: GRADLE_OPTS 注入 http 代理" "$MOCK_LOG" "-Dhttp.proxyHost=172.16.0.81 -Dhttp.proxyPort=7890"
assert_contains "用例6: GRADLE_OPTS 注入 https 代理" "$MOCK_LOG" "-Dhttps.proxyHost=172.16.0.81 -Dhttps.proxyPort=7890"
assert_contains "用例6: 仍执行 apk release 构建" "$MOCK_LOG" "flutter build apk --release"

# =============================================================================
# 用例 7：无代理环境变量时不注入 GRADLE_OPTS
# =============================================================================
CASE="$WORK/case7"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$WORK/mock-bin:$PATH"

env -u http_proxy -u https_proxy bash "$BUILD_SH" android release false >out.log 2>&1
rc=$?
assert_eq "用例7: 退出码为 0" "0" "$rc"
assert_not_contains "用例7: 无代理不注入 proxyHost" "$MOCK_LOG" "proxyHost"

# =============================================================================
# 用例 8：存在 JDK 17 时 JAVA_HOME 钉到 LTS（AGP JdkImageTransform 与 Java 26 不兼容）
# =============================================================================
CASE="$WORK/case8"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$WORK/mock-bin:$PATH"
cat > java_home_mock <<'M'
#!/usr/bin/env bash
if [ "${1:-}" = "-v" ] && [ "${2:-}" = "17" ]; then echo "/fake/jdk17/Home"; exit 0; fi
exit 1
M
chmod +x java_home_mock

MACRUNARA_JAVA_HOME_BIN="$CASE/java_home_mock" bash "$BUILD_SH" android release false >out.log 2>&1
rc=$?
assert_eq "用例8: 退出码为 0" "0" "$rc"
assert_contains "用例8: JAVA_HOME 钉到 JDK17" "out.log" "JAVA_HOME -> /fake/jdk17/Home"

# =============================================================================
# 用例 9：MACRUNARA_GRADLE_JDK=off 时跳过 JDK 钉版
# =============================================================================
CASE="$WORK/case9"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$WORK/mock-bin:$PATH"
cp "$WORK/case8/java_home_mock" . 2>/dev/null || cat > java_home_mock <<'M'
#!/usr/bin/env bash
if [ "${1:-}" = "-v" ] && [ "${2:-}" = "17" ]; then echo "/fake/jdk17/Home"; exit 0; fi
exit 1
M
chmod +x java_home_mock

MACRUNARA_GRADLE_JDK=off MACRUNARA_JAVA_HOME_BIN="$CASE/java_home_mock" bash "$BUILD_SH" android release false >out.log 2>&1
rc=$?
assert_eq "用例9: 退出码为 0" "0" "$rc"
assert_not_contains "用例9: off 时不钉 JAVA_HOME" "out.log" "JAVA_HOME ->"

# --- 汇总 ---------------------------------------------------------------------
echo ""
echo "==============================================="
echo "通过: $PASS  失败: $FAIL"
echo "==============================================="
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
echo "全部用例通过"
