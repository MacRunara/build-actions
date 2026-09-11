#!/usr/bin/env bash
# =============================================================================
# ios/tests/run_tests.sh — iOS action 脚本单元测试（零依赖 bash 套件）
#
# 原理：在临时目录中放置 mock xcodebuild（把完整参数记录到 $MOCK_LOG，
# 并按参数生成假 .app / .ipa），将其目录前置到 PATH，然后在独立的
# 用例子目录中调用 scripts/build.sh 与 scripts/export-archive.sh 断言行为。
#
# 本地运行：
#   cd build-actions
#   bash ios/tests/run_tests.sh
#
# 退出码：全部通过为 0；任一断言失败为 1。
# =============================================================================

# 注意：故意不使用 set -e——断言失败需要计数并继续跑完所有用例
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION_DIR="$(cd "$TESTS_DIR/.." && pwd)"
BUILD_SH="$ACTION_DIR/scripts/build.sh"
EXPORT_SH="$ACTION_DIR/scripts/export-archive.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

# assert_eq <描述> <期望值> <实际值>
assert_eq() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1（期望 [$2]，实际 [$3]）"; fi
}

# assert_file_exists <描述> <文件路径>
assert_file_exists() {
  if [ -f "$2" ]; then pass "$1"; else fail "$1（文件不存在: $2）"; fi
}

# assert_contains <描述> <文件> <固定字符串>
assert_contains() {
  if [ -f "$2" ] && grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1（$2 中未找到: $3）"; fi
}

# assert_not_contains <描述> <文件> <固定字符串>
assert_not_contains() {
  if [ ! -f "$2" ] || ! grep -qF -- "$3" "$2"; then pass "$1"; else fail "$1（$2 中不应出现: $3）"; fi
}

# --- 前置检查 -----------------------------------------------------------------
for f in "$BUILD_SH" "$EXPORT_SH"; do
  if [ ! -f "$f" ]; then
    echo "FATAL - 脚本不存在: $f"
    exit 1
  fi
done

# --- 构造临时工作区与 mock xcodebuild -----------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/mock-bin"
cat > "$WORK/mock-bin/xcodebuild" <<'MOCK'
#!/usr/bin/env bash
# Mock xcodebuild：记录完整参数到 $MOCK_LOG，并按参数生成假产物。
# 环境变量 MOCK_XCODEBUILD_EXPORT_FAIL=1 时，导出模式模拟失败（退出码 1）。
CONFIGURATION=Release
SDK=iphoneos
APP_NAME=MockApp
EXPORT=0
EXPORT_PATH=""

# 记录完整参数（一行），供断言 -project/-scheme 等是否出现
echo "$@" >> "$MOCK_LOG"

while [ $# -gt 0 ]; do
  case "$1" in
    -project) shift ;;
    -scheme) shift; APP_NAME="$1" ;;
    -configuration) shift; CONFIGURATION="$1" ;;
    -sdk) shift; SDK="$1" ;;
    -exportArchive) EXPORT=1 ;;
    -archivePath) shift ;;
    -exportPath) shift; EXPORT_PATH="$1" ;;
    -exportOptionsPlist) shift ;;
  esac
  shift
done

if [ "$EXPORT" = "1" ]; then
  if [ "${MOCK_XCODEBUILD_EXPORT_FAIL:-0}" = "1" ]; then
    echo "mock xcodebuild: export failed" >&2
    exit 1
  fi
  mkdir -p "$EXPORT_PATH"
  touch "$EXPORT_PATH/${APP_NAME}.ipa"
else
  OUT_DIR="build/${CONFIGURATION}-${SDK}"
  mkdir -p "$OUT_DIR"
  touch "$OUT_DIR/${APP_NAME}.app"
fi
MOCK
chmod +x "$WORK/mock-bin/xcodebuild"
export PATH="$WORK/mock-bin:$PATH"

# =============================================================================
# 用例 1：build.sh 不传 project 时不带 -project 参数
# =============================================================================
CASE="$WORK/case1"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"

bash "$BUILD_SH" "MyApp" "" "Release" "iphoneos" >out.log 2>&1
rc=$?
assert_eq "用例1: 不传 project 时退出码为 0" "0" "$rc"
assert_not_contains "用例1: 不传 project 时不带 -project 参数" "$MOCK_LOG" "-project"
assert_file_exists "用例1: 生成 build/Release-iphoneos/MyApp.app" "build/Release-iphoneos/MyApp.app"

# =============================================================================
# 用例 2：build.sh 传 project 时正确带 -project 路径
# =============================================================================
CASE="$WORK/case2"; mkdir -p "$CASE/MockProject.xcodeproj"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
touch "MockProject.xcodeproj/project.pbxproj"

bash "$BUILD_SH" "MyApp" "MockProject.xcodeproj" "Release" "iphoneos" >out.log 2>&1
rc=$?
assert_eq "用例2: 传 project 时退出码为 0" "0" "$rc"
assert_contains "用例2: 正确携带 -project 路径" "$MOCK_LOG" "-project MockProject.xcodeproj"

# =============================================================================
# 用例 3：build.sh 的 scheme / configuration / sdk 参数正确传递
# =============================================================================
CASE="$WORK/case3"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"

bash "$BUILD_SH" "AppScheme" "" "Debug" "macosx" >out.log 2>&1
rc=$?
assert_eq "用例3: 退出码为 0" "0" "$rc"
assert_contains "用例3: -scheme 正确传递" "$MOCK_LOG" "-scheme AppScheme"
assert_contains "用例3: -configuration 正确传递" "$MOCK_LOG" "-configuration Debug"
assert_contains "用例3: -sdk 正确传递" "$MOCK_LOG" "-sdk macosx"
assert_file_exists "用例3: 生成 build/Debug-macosx/AppScheme.app" "build/Debug-macosx/AppScheme.app"

# =============================================================================
# 用例 4：export-archive.sh 无 .xcarchive 时跳过导出且退出码 0
# =============================================================================
CASE="$WORK/case4"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"

out="$(bash "$EXPORT_SH" 2>&1)"
rc=$?
assert_eq "用例4: 无归档时退出码为 0" "0" "$rc"
if echo "$out" | grep -qF "skipping exportArchive"; then
  pass "用例4: 输出跳过提示"
else
  fail "用例4: 缺少跳过提示（实际输出: $out）"
fi
assert_not_contains "用例4: 未调用 -exportArchive" "$MOCK_LOG" "-exportArchive"

# =============================================================================
# 用例 5：export-archive.sh 有 .xcarchive 时调用 -exportArchive 并生成 IPA
# =============================================================================
CASE="$WORK/case5"; mkdir -p "$CASE/MyApp.xcarchive/Products/Applications"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
touch "MyApp.xcarchive/Info.plist"

bash "$EXPORT_SH" >out.log 2>&1
rc=$?
assert_eq "用例5: 有归档时退出码为 0" "0" "$rc"
assert_contains "用例5: 调用了 -exportArchive" "$MOCK_LOG" "-exportArchive"
assert_contains "用例5: 传入正确的 -archivePath" "$MOCK_LOG" "-archivePath ./MyApp.xcarchive"
assert_file_exists "用例5: 生成 build/Exported/MockApp.ipa" "build/Exported/MockApp.ipa"
assert_file_exists "用例5: 生成 exportOptions.plist" "exportOptions.plist"

# =============================================================================
# 用例 6：export-archive.sh 在 xcodebuild 导出失败时不致命（warning 语义）
# =============================================================================
CASE="$WORK/case6"; mkdir -p "$CASE/MyApp.xcarchive"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
touch "MyApp.xcarchive/Info.plist"
export MOCK_XCODEBUILD_EXPORT_FAIL=1

out="$(bash "$EXPORT_SH" 2>&1)"
rc=$?
unset MOCK_XCODEBUILD_EXPORT_FAIL
assert_eq "用例6: 导出失败时退出码仍为 0（不致命）" "0" "$rc"
if echo "$out" | grep -qF "::warning::exportArchive failed"; then
  pass "用例6: 输出 ::warning:: 告警"
else
  fail "用例6: 缺少 ::warning:: 告警（实际输出: $out）"
fi

# =============================================================================
# 用例 7：build.sh 默认追加免签名构建设置（CI 无证书环境）
# =============================================================================
CASE="$WORK/case7"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"

bash "$BUILD_SH" "MyApp" "" "Release" "iphoneos" >out.log 2>&1
rc=$?
assert_eq "用例7: 退出码为 0" "0" "$rc"
assert_contains "用例7: 携带 CODE_SIGNING_ALLOWED=NO" "$MOCK_LOG" "CODE_SIGNING_ALLOWED=NO"
assert_contains "用例7: 携带 CODE_SIGNING_REQUIRED=NO" "$MOCK_LOG" "CODE_SIGNING_REQUIRED=NO"
assert_file_exists "用例7: 仍正常生成 build/Release-iphoneos/MyApp.app" "build/Release-iphoneos/MyApp.app"

# --- 汇总 ---------------------------------------------------------------------
echo ""
echo "==============================================="
echo "通过: $PASS  失败: $FAIL"
echo "==============================================="
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
echo "全部用例通过"
