# Android 签名构建配置指南

> 适用：`macrunara/build-actions/android@v1`
> 状态：已在 android-test-build 仓库真机验证通过（2026-09-18，签名 `app-release.apk` 产出）

## 一、工作原理（30 秒版）

你把 keystore 以 base64 形式存进仓库 Secrets；每次 CI 运行时，action 会：

1. 把 keystore 解码到 runner 临时目录（随 job 结束销毁）；
2. 向 `~/.gradle/init.d/` 注入一个初始化脚本，在 Gradle 评估期为工程**新增** `signingConfigs.macrunaraCi`，并挂到所有名字含 `release` 的 buildType 上；
3. 正常执行 `assembleRelease` / `bundleRelease`，出来的 APK/AAB 就是签名包，经 GitHub Artifacts 交付。

**对客户工程零侵入**：不改 `build.gradle`、不改 `gradle.properties`，工程文件里看不到任何签名痕迹。debug 包不受影响，仍用默认 debug 证书。

> 注意：注入会**覆盖** release 系 buildType 上已有的 signingConfig。如果工程本身已配置 release 签名，Secrets 里的 keystore 将以 CI 为准。

## 二、准备 keystore（一次性，5 分钟）

已有 keystore 可跳过。没有则生成一个（在任意装有 JDK 的机器上执行）：

```bash
keytool -genkeypair -v \
  -keystore release.jks \
  -alias myapp \
  -keyalg RSA -keysize 2048 -validity 10950
```

- `-alias`：密钥别名，记牢，后面要配进 Secrets；
- `-validity 10950`：有效期 30 年（天），上架 Google Play 要求 2033 年后才到期；
- 交互中设置的** keystore 密码**和** key 密码**都要记牢。

> ⚠️ keystore 丢失 = 无法更新已上架应用。请离线妥善备份 `release.jks` 原件，不要只存在 Secrets 里。

## 三、base64 编码

```bash
# macOS / Linux
base64 -i release.jks | pbcopy && echo "已复制到剪贴板"

# Windows（git bash）
base64 -w0 release.jks | clip
```

要求**单行** base64（`-w0` / macOS 默认单行）。

## 四、配置仓库 Secrets

进入你的仓库 → **Settings → Secrets and variables → Actions → New repository secret**，添加 4 个：

| Secret 名 | 内容 |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | 上一步复制的 base64 |
| `ANDROID_KEYSTORE_PASSWORD` | keystore 密码 |
| `ANDROID_KEY_ALIAS` | 密钥别名（如 `myapp`） |
| `ANDROID_KEY_PASSWORD` | key 密码（通常与 keystore 密码相同） |

Secrets 在 CI 日志中全程 `::add-mask::` 打码，不会泄露。

## 五、配置 workflow

在你工程的 `.github/workflows/` 下新建（或改造现有 workflow）：

```yaml
name: Android Sign Release

on:
  workflow_dispatch:        # 手动触发；也可改成 push tag 等

jobs:
  build-sign-release:
    runs-on: [macos, arm64, macrunara]

    steps:
      - uses: actions/checkout@v4

      - uses: macrunara/setup-action@v1
        with:
          installation-id: ${{ secrets.MACRUNARA_INSTALLATION_ID }}
          region: auto

      - name: Build Signed Release & Upload
        uses: macrunara/build-actions/android@v1
        with:
          task: assembleRelease            # AAB 用 :app:bundleRelease
          module: app
          sign_keystore_base64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
          keystore_password:   ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
          key_alias:           ${{ secrets.ANDROID_KEY_ALIAS }}
          key_password:        ${{ secrets.ANDROID_KEY_PASSWORD }}
          upload_artifact: true
          artifact_name: android-release-signed-apk
          artifact_path: app/build/outputs/
```

**不提供 `sign_keystore_base64` 时行为完全不变**（免签名/debug 构建），老 workflow 零影响。

## 六、验证签名是否生效

Actions 页面 → 对应 run → 底部 **Artifacts** 下载 `android-release-signed-apk`。

构建日志中出现 `==> macrunara signing injected (release buildTypes)` 即注入成功。想进一步核验签名证书，可加一步：

```yaml
      - name: Verify signature
        run: |
          APK=$(ls app/build/outputs/apk/release/*.apk | head -1)
          # 节点装有多个 build-tools 版本，glob 取最新一个
          APKSIGNER=$(ls -d "$ANDROID_HOME/build-tools/"*/apksigner | sort -V | tail -1)
          "$APKSIGNER" verify --print-certs "$APK" | head -5
```

输出里的证书 SHA-256 应与你本地 `keytool -list -v -keystore release.jks` 看到的一致。

## 七、常见问题

**Q：构建报 `It is too late to add new signing configs`？**
A：v1 早期版本的注入时机 bug，已于 2026-09-18 修复（c514783）。确认 workflow 用的是最新 `@v1`；若怀疑 runner 缓存了旧 action，把引用临时改成完整 commit SHA 可强制绕过缓存。

**Q：我的工程有多个 module / flavor？**
A：`task` 支持完整任务名（如 `:app:assembleRelease`、`:app:bundleRelease`），`module` 留空则原样执行 `task`。flavor 场景注入同样生效（按 buildType 名字匹配 release）。

**Q：Flutter / React Native 工程怎么签？**
A：不用额外配置。`macrunara/build-actions/flutter@v1`、`/rn@v1` 的 Android 侧内部就是 Gradle 构建，提供同样的 4 个签名 inputs，init.d 注入自动生效。

**Q：签名包想直接发蒲公英/应用市场？**
A：本期产物统一经 GitHub Artifacts 交付，下载后自行分发。托管分发页在路线图第 3 批，暂缓中。
