#!/usr/bin/env bash
# =============================================================================
# setup-signing.sh — 临时 keychain + 签名证书/描述文件安装（V1.1-2.1）
#
# 由 ios/action.yml 的 "Setup signing keychain" 步骤调用：
#   bash "${{ github.action_path }}/scripts/setup-signing.sh" \
#     "<p12_base64>" "<p12_password>" "<mobileprovision_base64>" \
#     "<distribution>" "<out_env_file>"
#
# 位置参数：
#   $1 sign_p12_base64        .p12 证书的 base64（单行）
#   $2 sign_password          .p12 导出密码
#   $3 mobileprovision_base64 .mobileprovision 的 base64（单行）
#   $4 distribution           none|local|pgyer|testflight|firebase|development
#   $5 out_env_file           签名环境变量输出文件（默认 ./signing.env），
#                             action.yml 会把它 append 到 $GITHUB_ENV
#
# 安全约定：
#   - 密码/证书内容一律不打印（action.yml 已先 ::add-mask::）；
#   - keychain 为一次性临时文件（随 VM 销毁），密码用随机串，不落盘明文；
#   - 证书密码仅出现在 security import 命令行参数中（VM 用完即销毁，可接受）。
#
# 输出环境变量（写入 out_env_file）：
#   SIGNING_ENABLED / SIGN_KEYCHAIN_PATH / SIGN_IDENTITY / TEAM_ID /
#   PROFILE_UUID / PROFILE_NAME / EXPORT_METHOD
#
# distribution → EXPORT_METHOD 映射：
#   local / pgyer / firebase → ad-hoc；testflight → app-store。
#   pgyer / testflight / firebase 的上传分发本期暂缓（V1.1 第 3 批冻结，
#   9-18 决策），签名 IPA 统一经 GitHub Artifacts 交付。
# =============================================================================
set -euo pipefail

P12_B64="${1:-}"
P12_PASSWORD="${2:-}"
PROFILE_B64="${3:-}"
DISTRIBUTION="${4:-none}"
OUT_ENV="${5:-./signing.env}"

# distribution=none：显式关闭签名，保持历史行为（免签名构建）
if [ "$DISTRIBUTION" = "none" ]; then
  echo "SIGNING_ENABLED=0" > "$OUT_ENV"
  echo "distribution=none，跳过签名设置"
  exit 0
fi

case "$DISTRIBUTION" in
  local|pgyer|testflight|firebase|development) ;;
  *) echo "::error::未知 distribution: $DISTRIBUTION（可选 none|local|pgyer|testflight|firebase|development）"; exit 1 ;;
esac

if [ -z "$P12_B64" ] || [ -z "$PROFILE_B64" ]; then
  echo "::error::distribution=$DISTRIBUTION 需要同时提供 sign_p12_base64 与 mobileprovision_base64"
  exit 1
fi

case "$DISTRIBUTION" in
  pgyer|testflight|firebase)
    echo "::warning::分发上传（$DISTRIBUTION）本期暂缓，签名 IPA 将经 GitHub Artifacts 交付" ;;
esac

EXPORT_METHOD="ad-hoc"
if [ "$DISTRIBUTION" = "testflight" ]; then
  EXPORT_METHOD="app-store"
elif [ "$DISTRIBUTION" = "development" ]; then
  # 免费 Apple ID（Personal Team）/ 开发证书场景：只能出 development IPA
  EXPORT_METHOD="development"
fi

SIGN_DIR="${RUNNER_TEMP:-$PWD}/macrunara-signing"
mkdir -p "$SIGN_DIR"
chmod 700 "$SIGN_DIR"

P12_PATH="$SIGN_DIR/cert.p12"
PROFILE_PATH="$SIGN_DIR/profile.mobileprovision"
printf '%s' "$P12_B64" | base64 --decode > "$P12_PATH"
printf '%s' "$PROFILE_B64" | base64 --decode > "$PROFILE_PATH"

# --- 解析描述文件（security cms -D 输出 XML plist 到 stdout） -----------------
PROFILE_PLIST="$SIGN_DIR/profile.plist"
security cms -D -i "$PROFILE_PATH" > "$PROFILE_PLIST" 2>/dev/null

# extract_plist_string <key>：取 <key>KEY</key> 下一行的 <string> 值
extract_plist_string() {
  grep -A1 "<key>$1</key>" "$PROFILE_PLIST" | sed -nE 's:.*<string>([^<]+)</string>.*:\1:p' | head -1
}

PROFILE_UUID="$(extract_plist_string UUID)"
PROFILE_NAME="$(extract_plist_string Name)"
if [ -z "$PROFILE_UUID" ] || [ -z "$PROFILE_NAME" ]; then
  echo "::error::描述文件解析失败（缺 UUID/Name），请确认 mobileprovision_base64 有效"
  exit 1
fi

# 安装描述文件到 Xcode 约定目录（9-18 真机暴露：Xcode 16+ 已迁到
# UserData/Provisioning Profiles，老目录不再被读取——两个目录都装以兼容新旧 Xcode）
PROFILE_DESTS=(
  "$HOME/Library/MobileDevice/Provisioning Profiles"
  "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
)
for D in "${PROFILE_DESTS[@]}"; do
  mkdir -p "$D"
  cp "$PROFILE_PATH" "$D/$PROFILE_UUID.mobileprovision"
done

# --- 一次性临时 keychain -------------------------------------------------------
KEYCHAIN_PATH="$SIGN_DIR/macrunara-signing.keychain-db"
KEYCHAIN_PASSWORD="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid 2>/dev/null || echo "kc-$$-$RANDOM")"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"
# 构建期间不自动锁定
security set-keychain-settings -lut 3600 "$KEYCHAIN_PATH"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH"

# 把临时 keychain 加入搜索列表（保留原有 keychain）
EXISTING_KEYCHAINS="$(security list-keychains -d user | tr -d '"' || true)"
# shellcheck disable=SC2086
security list-keychains -d user -s "$KEYCHAIN_PATH" $EXISTING_KEYCHAINS

# 导入证书（-A：允许任何程序读取私钥，避免 codesign 弹窗卡住 CI）
security import "$P12_PATH" -P "$P12_PASSWORD" -k "$KEYCHAIN_PATH" -A
# 允许 codesign 等苹果工具无交互访问私钥分区
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_PATH" > /dev/null

# --- WWDR 中间证书（9-18 真机暴露）：临时 keychain 是全新的，没有 Apple WWDR
# 中间证书时证书链建不起来，find-identity 会报 0 valid identities。
# 获取顺序：MACRUNARA_WWDR_CERT 指定的本地文件 > 仓库内置 G3 证书
# （ios/certs/AppleWWDRCAG3.cer，有效期至 2030-02）> 从 apple.com 下载。
# 内置兜底的原因（9-20 真机暴露）：内网代理白名单只放行 GitHub 系域名，
# apple.com 不可达会导致证书链失效。
WWDR_CERT="$SIGN_DIR/AppleWWDRCAG3.cer"
BUNDLED_WWDR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/certs/AppleWWDRCAG3.cer"
if [ -n "${MACRUNARA_WWDR_CERT:-}" ]; then
  cp "${MACRUNARA_WWDR_CERT}" "$WWDR_CERT"
elif [ -f "$BUNDLED_WWDR" ]; then
  cp "$BUNDLED_WWDR" "$WWDR_CERT"
elif ! curl -fsSL --max-time 20 -o "$WWDR_CERT" "https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer" 2>/dev/null; then
  echo "::warning::WWDR 中间证书获取失败（内置缺失且下载失败，可用 MACRUNARA_WWDR_CERT 指定本地 .cer），继续尝试"
fi
if [ -f "$WWDR_CERT" ]; then
  security add-certificates -k "$KEYCHAIN_PATH" "$WWDR_CERT" || true
fi

# --- 推导签名身份与 Team ID ----------------------------------------------------
# 注意 grep '"' 过滤：0 个有效身份时 find-identity 只输出 "0 valid identities found"，
# 不过滤会把这行当成身份名带进 CODE_SIGN_IDENTITY（9-18 真机暴露）
IDENTITY_LINE="$(security find-identity -v -p codesigning "$KEYCHAIN_PATH" | grep '"' | head -1 || true)"
SIGN_IDENTITY="$(printf '%s' "$IDENTITY_LINE" | sed -E 's/.*"([^"]+)".*/\1/')"
if [ -z "$SIGN_IDENTITY" ]; then
  echo "::error::keychain 内无有效签名身份（0 valid identities）——p12 私钥/证书不匹配，或证书链无效（WWDR 缺失）"
  exit 1
fi

# Team ID 提取（9-20 真机暴露）：企业证书 CN 括号即 Team ID，但 Personal Team
# 证书 CN 括号是个人 ID、OU 字段才是真 Team ID（subject 形如
# C=US,O=姓名,OU=UXAPAYMP76,CN=Apple Development: xxx (4T3477P8FT)）。
# 优先取 OU，取不到再回退 CN 括号
CERT_PEM="$SIGN_DIR/identity.pem"
CERT_TEAM=""
CERT_SUBJ=""
if security find-certificate -c "$SIGN_IDENTITY" -p "$KEYCHAIN_PATH" > "$CERT_PEM" 2>/dev/null && [ -s "$CERT_PEM" ]; then
  CERT_SUBJ="$(openssl x509 -in "$CERT_PEM" -noout -subject -nameopt RFC2253 2>&1 || true)"
  CERT_TEAM=$(printf '%s' "$CERT_SUBJ" | sed -nE 's/.*OU=([A-Z0-9]+).*/\1/p' || true)
  # 兼容 oneline 旧格式（/OU=XXX/）与空格变体（OU = XXX）
  [ -z "$CERT_TEAM" ] && CERT_TEAM=$(printf '%s' "$CERT_SUBJ" | sed -nE 's|.*OU ?= ?([A-Z0-9]+).*|\1|p' || true)
else
  CERT_SUBJ="<security find-certificate 无输出>"
fi
echo "[macrunara] 证书 subject: ${CERT_SUBJ:-<openssl 提取失败>}"
[ -z "$CERT_TEAM" ] && CERT_TEAM="$(printf '%s' "$IDENTITY_LINE" | sed -nE 's/.*\(([A-Z0-9]+)\).*/\1/p')"
echo "[macrunara] CERT_TEAM=${CERT_TEAM:-<空>}（OU 优先，取空才用 CN 括号兜底）"

# 描述文件 Team（application-identifier 形如 TEAMID.com.example.app）
APP_ID="$(extract_plist_string "application-identifier")"
PROFILE_TEAM="${APP_ID%%.*}"
echo "[macrunara] PROFILE_TEAM=${PROFILE_TEAM:-<空>} APP_ID=${APP_ID:-<空>}"

# 9-18 真机暴露：证书与描述文件分属不同 Team 时 xcodebuild 才报匹配失败，
# 在这里提前拦截并给出可操作提示
if [ -n "$CERT_TEAM" ] && [ -n "$PROFILE_TEAM" ] && [ "$CERT_TEAM" != "$PROFILE_TEAM" ]; then
  echo "::error::证书 Team（$CERT_TEAM）与描述文件 Team（$PROFILE_TEAM）不一致——p12 与 mobileprovision 必须来自同一个 Apple 开发者团队，请重新导出/生成后再试"
  exit 1
fi
TEAM_ID="${CERT_TEAM:-$PROFILE_TEAM}"
if [ -z "$TEAM_ID" ]; then
  echo "::error::未能推导 Team ID，请确认描述文件含 application-identifier"
  exit 1
fi

{
  echo "SIGNING_ENABLED=1"
  echo "SIGN_KEYCHAIN_PATH=$KEYCHAIN_PATH"
  echo "SIGN_IDENTITY=$SIGN_IDENTITY"
  echo "TEAM_ID=$TEAM_ID"
  echo "PROFILE_UUID=$PROFILE_UUID"
  echo "PROFILE_NAME=$PROFILE_NAME"
  echo "EXPORT_METHOD=$EXPORT_METHOD"
} > "$OUT_ENV"

echo "签名环境就绪：TEAM_ID=$TEAM_ID  PROFILE=$PROFILE_NAME（$PROFILE_UUID）  METHOD=$EXPORT_METHOD"
