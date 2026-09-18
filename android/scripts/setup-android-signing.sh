#!/usr/bin/env bash
# =============================================================================
# setup-android-signing.sh — Android keystore 签名注入（V1.1-2.1）
#
# 供 android / flutter / react-native 三个 action 共用：
#   bash setup-android-signing.sh <keystore_base64> <store_password> <key_alias> <key_password> [out_env]
#
# 零侵入原理：把签名配置写成 Gradle init script 放入
# ${GRADLE_USER_HOME:-~/.gradle}/init.d/，该目录下的脚本对**所有** Gradle
# 调用自动生效（含 flutter build apk / RN android/ 内 gradlew），客户
# build.gradle 无需任何改动。init script 在 MACRUNARA_KEYSTORE_PATH 未设置时
# 直接 no-op，不会误伤未传签名的 job。
#
# 行为：
#   - keystore 解码到 ${RUNNER_TEMP}/macrunara-signing/keystore.jks（0600）；
#   - 只覆盖 release 系 buildType 的 signingConfig（debug 保持默认 debug 证书）；
#   - 密码只经环境变量传给 Gradle 进程，不写进 init script 明文（脚本内是
#     System.getenv 读取），日志不回显（action.yml 已先 ::add-mask::）。
# =============================================================================
set -euo pipefail

KEYSTORE_B64="${1:-}"
STORE_PASSWORD="${2:-}"
KEY_ALIAS="${3:-}"
KEY_PASSWORD="${4:-}"
OUT_ENV="${5:-./android-signing.env}"

if [ -z "$KEYSTORE_B64" ]; then
  echo "未提供 sign_keystore_base64，跳过 Android 签名设置"
  exit 0
fi
if [ -z "$STORE_PASSWORD" ] || [ -z "$KEY_ALIAS" ]; then
  echo "::error::Android 签名需要 sign_keystore_base64 + keystore_password + key_alias"
  exit 1
fi

SIGN_DIR="${RUNNER_TEMP:-$PWD}/macrunara-signing"
mkdir -p "$SIGN_DIR"
chmod 700 "$SIGN_DIR"

KEYSTORE_PATH="$SIGN_DIR/keystore.jks"
printf '%s' "$KEYSTORE_B64" | base64 --decode > "$KEYSTORE_PATH"
chmod 600 "$KEYSTORE_PATH"

GRADLE_HOME="${GRADLE_USER_HOME:-$HOME/.gradle}"
INIT_DIR="$GRADLE_HOME/init.d"
mkdir -p "$INIT_DIR"

cat > "$INIT_DIR/macrunara-signing.gradle" <<'EOF'
// Macrunara CI 零侵入签名注入（V1.1-2.1）：未设置 MACRUNARA_KEYSTORE_PATH 时 no-op。
def macrunaraKs = System.getenv('MACRUNARA_KEYSTORE_PATH')
if (macrunaraKs != null && macrunaraKs.length() > 0) {
  gradle.projectsEvaluated {
    gradle.rootProject.allprojects { p ->
      p.plugins.withId('com.android.application') {
        def androidExt = p.extensions.findByName('android')
        if (androidExt != null) {
          androidExt.signingConfigs {
            macrunaraCi {
              storeFile file(macrunaraKs)
              storePassword System.getenv('MACRUNARA_KEYSTORE_PASSWORD')
              keyAlias System.getenv('MACRUNARA_KEY_ALIAS')
              keyPassword System.getenv('MACRUNARA_KEY_PASSWORD')
            }
          }
          androidExt.buildTypes.all { bt ->
            if (bt.name.toLowerCase().contains('release')) {
              bt.signingConfig = androidExt.signingConfigs.macrunaraCi
            }
          }
          p.logger.lifecycle('==> macrunara signing injected (release buildTypes)')
        }
      }
    }
  }
}
EOF

{
  echo "MACRUNARA_KEYSTORE_PATH=$KEYSTORE_PATH"
  echo "MACRUNARA_KEYSTORE_PASSWORD=$STORE_PASSWORD"
  echo "MACRUNARA_KEY_ALIAS=$KEY_ALIAS"
  echo "MACRUNARA_KEY_PASSWORD=$KEY_PASSWORD"
  echo "ANDROID_SIGNING_ENABLED=1"
} > "$OUT_ENV"

echo "Android 签名就绪：keystore=$KEYSTORE_PATH alias=$KEY_ALIAS（release 构建自动签名）"
