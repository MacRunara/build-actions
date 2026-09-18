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

# =============================================================================
# 用例 8：build.sh 显式指定 SYMROOT（产物路径与 action 默认 artifact_path 对齐）
# 回归防护：2026-09-16 发现未指定 SYMROOT 时产物落 DerivedData，
# upload-artifact 对 build/Release-iphoneos 永远 "No files found" 静默跳过。
# =============================================================================
CASE="$WORK/case8"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"

bash "$BUILD_SH" "MyApp" "" "Release" "iphoneos" >out.log 2>&1
rc=$?
assert_eq "用例8: 退出码为 0" "0" "$rc"
assert_contains "用例8: 显式携带 SYMROOT" "$MOCK_LOG" "SYMROOT="
assert_contains "用例8: SYMROOT 指向工作区 build 目录" "$MOCK_LOG" "SYMROOT=$CASE/build"

# =============================================================================
# 用例 9：GITHUB_WORKSPACE 存在时 SYMROOT 以其为准
# =============================================================================
CASE="$WORK/case9"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export GITHUB_WORKSPACE="$WORK/fake-workspace"

bash "$BUILD_SH" "MyApp" "" "Release" "iphoneos" >out.log 2>&1
rc=$?
unset GITHUB_WORKSPACE
assert_eq "用例9: 退出码为 0" "0" "$rc"
assert_contains "用例9: SYMROOT 使用 GITHUB_WORKSPACE" "$MOCK_LOG" "SYMROOT=$WORK/fake-workspace/build"

SETUP_SH="$ACTION_DIR/scripts/setup-signing.sh"

# =============================================================================
# 用例 10：setup-signing.sh happy path（distribution=local）
# mock security：记录参数、find-identity 返回假身份、cms 输出假描述文件 plist
# =============================================================================
CASE="$WORK/case10"; mkdir -p "$CASE/home"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export MOCK_SECURITY_LOG="$CASE/security.log"

cat > "$WORK/mock-bin/security" <<'MOCK'
#!/usr/bin/env bash
echo "$@" >> "$MOCK_SECURITY_LOG"
case "$1" in
  find-identity) echo '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "iPhone Distribution: Mock Team (TEAM123)"' ;;
  cms) cat "$MOCK_PROFILE_PLIST" ;;
  list-keychains) echo "$HOME/Library/Keychains/login.keychain-db" ;;
esac
MOCK
chmod +x "$WORK/mock-bin/security"

cat > "$CASE/fake-profile.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>UUID</key>
  <string>UUID-1234-ABCD</string>
  <key>Name</key>
  <string>MockProfile</string>
  <key>Entitlements</key>
  <dict>
    <key>application-identifier</key>
    <string>TEAM123.com.mock.app</string>
  </dict>
</dict></plist>
EOF

export HOME="$CASE/home"
export MOCK_PROFILE_PLIST="$CASE/fake-profile.plist"
P12_B64="$(printf 'fake-p12-bytes' | base64 -w0)"
PROFILE_B64="$(base64 -w0 < "$CASE/fake-profile.plist")"

bash "$SETUP_SH" "$P12_B64" "s3cret-pw" "$PROFILE_B64" "local" "$CASE/signing.env" >out.log 2>&1
rc=$?
assert_eq "用例10: setup-signing 退出码为 0" "0" "$rc"
assert_contains "用例10: signing.env 启用签名" "$CASE/signing.env" "SIGNING_ENABLED=1"
assert_contains "用例10: 推导 TEAM_ID" "$CASE/signing.env" "TEAM_ID=TEAM123"
assert_contains "用例10: 解析 PROFILE_UUID" "$CASE/signing.env" "PROFILE_UUID=UUID-1234-ABCD"
assert_contains "用例10: 解析 PROFILE_NAME" "$CASE/signing.env" "PROFILE_NAME=MockProfile"
assert_contains "用例10: local 映射 ad-hoc" "$CASE/signing.env" "EXPORT_METHOD=ad-hoc"
assert_contains "用例10: 创建临时 keychain" "$MOCK_SECURITY_LOG" "create-keychain"
assert_contains "用例10: 导入 p12 证书" "$MOCK_SECURITY_LOG" "import"
assert_contains "用例10: 设置私钥分区列表" "$MOCK_SECURITY_LOG" "set-key-partition-list"
assert_file_exists "用例10: 描述文件安装到 Provisioning Profiles" "$CASE/home/Library/MobileDevice/Provisioning Profiles/UUID-1234-ABCD.mobileprovision"
assert_not_contains "用例10: 日志不泄露证书密码" "$CASE/out.log" "s3cret-pw"
assert_not_contains "用例10: 日志不泄露 p12 base64" "$CASE/out.log" "$P12_B64"

# =============================================================================
# 用例 11：distribution=none 时不签名、不碰 keychain
# =============================================================================
CASE="$WORK/case11"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_SECURITY_LOG="$CASE/security.log"

bash "$SETUP_SH" "" "" "" "none" "$CASE/signing.env" >out.log 2>&1
rc=$?
assert_eq "用例11: none 退出码为 0" "0" "$rc"
assert_contains "用例11: SIGNING_ENABLED=0" "$CASE/signing.env" "SIGNING_ENABLED=0"
assert_eq "用例11: 未调用 security" "0" "$([ -f "$MOCK_SECURITY_LOG" ] && echo 1 || echo 0)"

# =============================================================================
# 用例 12：上传型分发暂缓（pgyer→warning+ad-hoc，testflight→app-store）
# =============================================================================
CASE="$WORK/case12"; mkdir -p "$CASE/home"; cd "$CASE"
export HOME="$CASE/home"
export MOCK_SECURITY_LOG="$CASE/security.log"
export MOCK_PROFILE_PLIST="$WORK/case10/fake-profile.plist"
P12_B64="$(printf 'fake-p12-bytes' | base64 -w0)"
PROFILE_B64="$(base64 -w0 < "$MOCK_PROFILE_PLIST")"

out="$(bash "$SETUP_SH" "$P12_B64" "pw" "$PROFILE_B64" "pgyer" "$CASE/signing-pgyer.env" 2>&1)"
rc=$?
assert_eq "用例12: pgyer 退出码为 0" "0" "$rc"
if echo "$out" | grep -qF "::warning::分发上传"; then
  pass "用例12: pgyer 输出暂缓 warning"
else
  fail "用例12: pgyer 缺少暂缓 warning（实际输出: $out）"
fi
assert_contains "用例12: pgyer 映射 ad-hoc" "$CASE/signing-pgyer.env" "EXPORT_METHOD=ad-hoc"

bash "$SETUP_SH" "$P12_B64" "pw" "$PROFILE_B64" "testflight" "$CASE/signing-tf.env" >out-tf.log 2>&1
assert_contains "用例12: testflight 映射 app-store" "$CASE/signing-tf.env" "EXPORT_METHOD=app-store"

out="$(bash "$SETUP_SH" "$P12_B64" "pw" "$PROFILE_B64" "bogus" "$CASE/signing-x.env" 2>&1 || true)"
if echo "$out" | grep -qF "::error::未知 distribution"; then
  pass "用例12: 非法 distribution 报错"
else
  fail "用例12: 非法 distribution 未报错（实际输出: $out）"
fi

# =============================================================================
# 用例 13：build.sh 在 SIGNING_ENABLED=1 时切换手动签名 archive 模式
# =============================================================================
CASE="$WORK/case13"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"

SIGNING_ENABLED=1 TEAM_ID=TEAM123 PROFILE_NAME=MockProfile \
  SIGN_IDENTITY="iPhone Distribution: Mock Team (TEAM123)" \
  bash "$BUILD_SH" "MyApp" "" "Release" "iphoneos" >out.log 2>&1
rc=$?
assert_eq "用例13: 签名 archive 退出码为 0" "0" "$rc"
assert_contains "用例13: 使用 archive 动作" "$MOCK_LOG" "archive"
assert_contains "用例13: 携带 -archivePath" "$MOCK_LOG" "-archivePath"
assert_contains "用例13: 手动签名 CODE_SIGN_STYLE=Manual" "$MOCK_LOG" "CODE_SIGN_STYLE=Manual"
assert_contains "用例13: 携带 DEVELOPMENT_TEAM" "$MOCK_LOG" "DEVELOPMENT_TEAM=TEAM123"
assert_contains "用例13: 携带 PROVISIONING_PROFILE_SPECIFIER" "$MOCK_LOG" "PROVISIONING_PROFILE_SPECIFIER=MockProfile"
assert_contains "用例13: 携带 CODE_SIGN_IDENTITY" "$MOCK_LOG" "CODE_SIGN_IDENTITY=iPhone Distribution: Mock Team (TEAM123)"
assert_not_contains "用例13: 签名模式不再带 CODE_SIGNING_ALLOWED=NO" "$MOCK_LOG" "CODE_SIGNING_ALLOWED=NO"

# =============================================================================
# 用例 14：export-archive.sh 签名导出（手动签名 + ad-hoc + teamID）
# =============================================================================
CASE="$WORK/case14"; mkdir -p "$CASE/MyApp.xcarchive"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
touch "MyApp.xcarchive/Info.plist"   # 空 plist：Bundle ID 提取失败，省略 provisioningProfiles

SIGNING_ENABLED=1 EXPORT_METHOD=ad-hoc TEAM_ID=TEAM123 PROFILE_NAME=MockProfile \
  bash "$EXPORT_SH" >out.log 2>&1
rc=$?
assert_eq "用例14: 签名导出退出码为 0" "0" "$rc"
assert_contains "用例14: 调用了 -exportArchive" "$MOCK_LOG" "-exportArchive"
assert_contains "用例14: method=ad-hoc" "$CASE/exportOptions.plist" "<string>ad-hoc</string>"
assert_contains "用例14: signingStyle=manual" "$CASE/exportOptions.plist" "<string>manual</string>"
assert_contains "用例14: 携带 teamID" "$CASE/exportOptions.plist" "<string>TEAM123</string>"
assert_not_contains "用例14: 无 Bundle ID 时省略 provisioningProfiles" "$CASE/exportOptions.plist" "provisioningProfiles"

# --- 汇总 ---------------------------------------------------------------------
echo ""
echo "==============================================="
echo "通过: $PASS  失败: $FAIL"
echo "==============================================="
if [ "$FAIL" -ne 0 ]; then
  exit 1
fi
echo "全部用例通过"
