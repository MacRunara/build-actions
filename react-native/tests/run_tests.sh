#!/usr/bin/env bash
# =============================================================================
# react-native/tests/run_tests.sh — RN action 脚本单元测试（零依赖 bash 套件）
#
# 原理：mock npm/yarn/pod/xcodebuild（调用序列记录到 $MOCK_LOG，
# xcodebuild 生成假 .app），前置 PATH 后调用 scripts/build.sh 断言链路行为。
#
# 本地运行：
#   cd build-actions
#   bash react-native/tests/run_tests.sh
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

# build.sh 会向 ~/.gradle/init.d 注入 maven 镜像脚本，统一重定向到 WORK 内
export GRADLE_USER_HOME="$WORK/global-gradle-home"

# --- mock 工具集 ----------------------------------------------------------------
MOCKBIN="$WORK/mock-bin"; mkdir -p "$MOCKBIN"

cat > "$MOCKBIN/npm" <<'MOCK'
#!/usr/bin/env bash
echo "npm $@" >> "$MOCK_LOG"
# build.sh 现在校验 npm ci 的结果（node_modules 必须存在），mock 需模拟安装成功
case " $* " in *" ci "*) mkdir -p node_modules && touch node_modules/.mock-installed;; esac
MOCK

cat > "$MOCKBIN/yarn" <<'MOCK'
#!/usr/bin/env bash
echo "yarn $@" >> "$MOCK_LOG"
MOCK

cat > "$MOCKBIN/pod" <<'MOCK'
#!/usr/bin/env bash
echo "pod $@" >> "$MOCK_LOG"
MOCK

cat > "$MOCKBIN/xcodebuild" <<'MOCK'
#!/usr/bin/env bash
echo "xcodebuild $@" >> "$MOCK_LOG"
mkdir -p build/DerivedData/Build/Products/Debug-iphonesimulator
touch build/DerivedData/Build/Products/Debug-iphonesimulator/MyApp.app
MOCK

chmod +x "$MOCKBIN/"{npm,yarn,pod,xcodebuild}

# =============================================================================
# 用例 1：npm 全链路（ci → pod install → npm test → xcodebuild 模拟器）
# =============================================================================
CASE="$WORK/case1"; mkdir -p "$CASE/ios"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$MOCKBIN:$PATH"
touch ios/Podfile

bash "$BUILD_SH" "npm" "ios/MyApp.xcworkspace" "MyApp" "" "true" >out.log 2>&1
rc=$?
assert_eq "用例1: 退出码为 0" "0" "$rc"
assert_contains "用例1: npm ci" "$MOCK_LOG" "npm ci"
assert_contains "用例1: pod install" "$MOCK_LOG" "pod install"
assert_contains "用例1: npm test" "$MOCK_LOG" "npm test"
assert_contains "用例1: xcodebuild 带 workspace" "$MOCK_LOG" "-workspace ios/MyApp.xcworkspace"
assert_contains "用例1: xcodebuild 模拟器目标" "$MOCK_LOG" "generic/platform=iOS Simulator"
assert_file_exists "用例1: 生成模拟器 .app" "build/DerivedData/Build/Products/Debug-iphonesimulator/MyApp.app"

# =============================================================================
# 用例 2：yarn 链路（yarn install --frozen-lockfile + yarn test）
# =============================================================================
CASE="$WORK/case2"; mkdir -p "$CASE/ios"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$MOCKBIN:$PATH"
touch ios/Podfile

bash "$BUILD_SH" "yarn" "ios/MyApp.xcworkspace" "MyApp" "" "true" >out.log 2>&1
rc=$?
assert_eq "用例2: 退出码为 0" "0" "$rc"
assert_contains "用例2: yarn install --frozen-lockfile" "$MOCK_LOG" "yarn install --frozen-lockfile"
assert_contains "用例2: yarn test" "$MOCK_LOG" "yarn test"
assert_not_contains "用例2: 不调用 npm" "$MOCK_LOG" "npm ci"

# =============================================================================
# 用例 3：无 Podfile 跳过 pod install；run-tests=false 跳过 JS 测试
# =============================================================================
CASE="$WORK/case3"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$MOCKBIN:$PATH"

bash "$BUILD_SH" "npm" "ios/MyApp.xcworkspace" "MyApp" "" "false" >out.log 2>&1
rc=$?
assert_eq "用例3: 退出码为 0" "0" "$rc"
assert_contains "用例3: 仍有 npm ci" "$MOCK_LOG" "npm ci"
assert_not_contains "用例3: 无 Podfile 不执行 pod install" "$MOCK_LOG" "pod install"
assert_not_contains "用例3: 跳过 npm test" "$MOCK_LOG" "npm test"
assert_contains "用例3: 仍执行 iOS 构建" "$MOCK_LOG" "-workspace ios/MyApp.xcworkspace"

# =============================================================================
# 用例 4：workspace 非空但 scheme 为空 → 退出码 1 + ::error::
# =============================================================================
CASE="$WORK/case4"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$MOCKBIN:$PATH"

out="$(bash "$BUILD_SH" "npm" "ios/MyApp.xcworkspace" "" "" "false" 2>&1)"
rc=$?
assert_eq "用例4: 缺 scheme 退出码为 1" "1" "$rc"
if echo "$out" | grep -qF "::error::ios-scheme is required"; then
  pass "用例4: 输出 ::error:: 提示"
else
  fail "用例4: 缺少 ::error:: 提示（实际输出: $out）"
fi
assert_not_contains "用例4: 未执行 xcodebuild" "$MOCK_LOG" "xcodebuild"

# =============================================================================
# 用例 5：双端构建（android-task 非空时在 android/ 内跑 gradlew）
# =============================================================================
CASE="$WORK/case5"; mkdir -p "$CASE/android"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$MOCKBIN:$PATH"
cat > android/gradlew <<'MOCK'
#!/usr/bin/env bash
echo "gradlew $@" >> "$MOCK_LOG"
MOCK
chmod +x android/gradlew

bash "$BUILD_SH" "npm" "" "" "assembleDebug" "false" >out.log 2>&1
rc=$?
assert_eq "用例5: 退出码为 0" "0" "$rc"
assert_contains "用例5: android/ 内执行 gradlew assembleDebug" "$MOCK_LOG" "gradlew assembleDebug --no-daemon"
assert_not_contains "用例5: workspace 为空不执行 xcodebuild" "$MOCK_LOG" "xcodebuild"

# =============================================================================
# 用例 5b：设置 https_proxy 时向 gradlew 注入 JVM 代理参数（JVM 不读 *_proxy 环境变量）
# =============================================================================
CASE="$WORK/case5b"; mkdir -p "$CASE/android"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$MOCKBIN:$PATH"
cat > android/gradlew <<'MOCK'
#!/usr/bin/env bash
echo "gradlew $@ | GRADLE_OPTS=${GRADLE_OPTS:-}" >> "$MOCK_LOG"
MOCK
chmod +x android/gradlew

https_proxy=http://192.0.2.1:7890 bash "$BUILD_SH" "npm" "" "" "assembleDebug" "false" >out.log 2>&1
rc=$?
assert_eq "用例5b: 退出码为 0" "0" "$rc"
assert_contains "用例5b: GRADLE_OPTS 注入代理参数" "$MOCK_LOG" "-Dhttps.proxyHost=192.0.2.1 -Dhttps.proxyPort=7890"
assert_contains "用例5b: 仍执行 gradlew assembleDebug" "$MOCK_LOG" "gradlew assembleDebug --no-daemon"

# =============================================================================
# 用例 5c：存在 JDK 17 时 JAVA_HOME 钉到 LTS（AGP JdkImageTransform 与 Java 26 不兼容）
# =============================================================================
CASE="$WORK/case5c"; mkdir -p "$CASE/android"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$MOCKBIN:$PATH"
cat > android/gradlew <<'MOCK'
#!/usr/bin/env bash
echo "gradlew $@" >> "$MOCK_LOG"
MOCK
chmod +x android/gradlew
cat > java_home_mock <<'M'
#!/usr/bin/env bash
if [ "${1:-}" = "-v" ] && [ "${2:-}" = "17" ]; then echo "/fake/jdk17/Home"; exit 0; fi
exit 1
M
chmod +x java_home_mock

MACRUNARA_JAVA_HOME_BIN="$CASE/java_home_mock" bash "$BUILD_SH" "npm" "" "" "assembleDebug" "false" >out.log 2>&1
rc=$?
assert_eq "用例5c: 退出码为 0" "0" "$rc"
assert_contains "用例5c: JAVA_HOME 钉到 JDK17" "out.log" "JAVA_HOME -> /fake/jdk17/Home"

# =============================================================================
# 用例 6：非法 package-manager → 退出码 1
# =============================================================================
CASE="$WORK/case6"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$MOCKBIN:$PATH"

out="$(bash "$BUILD_SH" "pnpm" "" "" "" "false" 2>&1)"
rc=$?
assert_eq "用例6: 非法 package-manager 退出码为 1" "1" "$rc"
if echo "$out" | grep -qF "::error::package-manager must be npm|yarn"; then
  pass "用例6: 输出 ::error:: 提示"
else
  fail "用例6: 缺少 ::error:: 提示（实际输出: $out）"
fi

# =============================================================================
# 用例 7：SIGNING_ENABLED=1 → 手动签名 archive + exportArchive（V1.1-2.1）
# =============================================================================
CASE="$WORK/case7"; mkdir -p "$CASE/ios/MyApp.xcodeproj"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$MOCKBIN:$PATH"
cat > ios/MyApp.xcodeproj/project.pbxproj <<'PBX'
		PRODUCT_BUNDLE_IDENTIFIER = com.mock.rnapp;
PBX

SIGNING_ENABLED=1 TEAM_ID=TEAM123 PROFILE_NAME=MockProfile \
SIGN_IDENTITY="iPhone Distribution: Mock Team (TEAM123)" EXPORT_METHOD=ad-hoc \
  bash "$BUILD_SH" "npm" "ios/MyApp.xcworkspace" "MyApp" "" "false" >out.log 2>&1
rc=$?
assert_eq "用例7: 退出码为 0" "0" "$rc"
assert_contains "用例7: 执行 xcodebuild archive" "$MOCK_LOG" "xcodebuild archive"
assert_contains "用例7: 手动签名" "$MOCK_LOG" "CODE_SIGN_STYLE=Manual"
assert_contains "用例7: DEVELOPMENT_TEAM 注入" "$MOCK_LOG" "DEVELOPMENT_TEAM=TEAM123"
assert_contains "用例7: PROVISIONING_PROFILE_SPECIFIER 注入" "$MOCK_LOG" "PROVISIONING_PROFILE_SPECIFIER=MockProfile"
assert_contains "用例7: 真机 sdk" "$MOCK_LOG" "-sdk iphoneos"
assert_not_contains "用例7: 不走模拟器目标" "$MOCK_LOG" "generic/platform=iOS Simulator"
assert_contains "用例7: 执行 -exportArchive" "$MOCK_LOG" "-exportArchive"
assert_contains "用例7: exportOptions method=ad-hoc" "exportOptions.plist" "<string>ad-hoc</string>"
assert_contains "用例7: exportOptions 手动签名" "exportOptions.plist" "<string>manual</string>"
assert_contains "用例7: 从 pbxproj 提取 Bundle ID 生成 provisioningProfiles" "exportOptions.plist" "<key>com.mock.rnapp</key>"

# =============================================================================
# 用例 8：SIGNING_ENABLED=0（默认）→ 保持模拟器 Debug 构建，不产生 exportOptions
# =============================================================================
CASE="$WORK/case8"; mkdir -p "$CASE"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$MOCKBIN:$PATH"

bash "$BUILD_SH" "npm" "ios/MyApp.xcworkspace" "MyApp" "" "false" >out.log 2>&1
rc=$?
assert_eq "用例8: 退出码为 0" "0" "$rc"
assert_contains "用例8: 模拟器目标构建" "$MOCK_LOG" "generic/platform=iOS Simulator"
assert_not_contains "用例8: 不执行 archive" "$MOCK_LOG" "xcodebuild archive"
assert_not_contains "用例8: 不执行 -exportArchive" "$MOCK_LOG" "-exportArchive"
assert_not_contains "用例8: 不生成 exportOptions.plist" "exportOptions.plist" "<plist"

# =============================================================================
# 用例 9：android-task 非空时默认注入 maven 镜像 init.d 脚本
# =============================================================================
CASE="$WORK/case9"; mkdir -p "$CASE/android"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$MOCKBIN:$PATH"
export GRADLE_USER_HOME="$CASE/gradle-home"
cat > android/gradlew <<'MOCK'
#!/usr/bin/env bash
echo "gradlew $@" >> "$MOCK_LOG"
MOCK
chmod +x android/gradlew

bash "$BUILD_SH" "npm" "" "" "assembleDebug" "false" >out.log 2>&1
rc=$?
assert_eq "用例9: 退出码为 0" "0" "$rc"
assert_file_exists "用例9: init.d 镜像脚本生成" "$CASE/gradle-home/init.d/macrunara-maven-mirrors.gradle"
assert_contains "用例9: 含 aliyun gradle-plugin 镜像" "$CASE/gradle-home/init.d/macrunara-maven-mirrors.gradle" "https://maven.aliyun.com/repository/gradle-plugin"
assert_contains "用例9: 覆盖插件门户（beforeSettings，求值前注入）" "$CASE/gradle-home/init.d/macrunara-maven-mirrors.gradle" "gradle.beforeSettings"
assert_contains "用例9: 日志提示镜像注入" "out.log" "maven mirrors -> aliyun"
assert_contains "用例9: 仍执行 gradlew assembleDebug" "$MOCK_LOG" "gradlew assembleDebug --no-daemon"
unset GRADLE_USER_HOME

# =============================================================================
# 用例 10：MACRUNARA_MAVEN_MIRROR=off → 不生成 init.d 镜像脚本
# =============================================================================
CASE="$WORK/case10"; mkdir -p "$CASE/android"; cd "$CASE"
export MOCK_LOG="$CASE/mock.log"
export PATH="$MOCKBIN:$PATH"
export GRADLE_USER_HOME="$CASE/gradle-home"
cat > android/gradlew <<'MOCK'
#!/usr/bin/env bash
echo "gradlew $@" >> "$MOCK_LOG"
MOCK
chmod +x android/gradlew

MACRUNARA_MAVEN_MIRROR=off bash "$BUILD_SH" "npm" "" "" "assembleDebug" "false" >out.log 2>&1
rc=$?
assert_eq "用例10: 退出码为 0" "0" "$rc"
assert_eq "用例10: 不生成 init 脚本" "0" "$([ -f "$CASE/gradle-home/init.d/macrunara-maven-mirrors.gradle" ] && echo 1 || echo 0)"
assert_contains "用例10: 日志提示已关闭" "out.log" "maven mirrors disabled"
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
