# iOS 签名构建配置指南

> 适用：`macrunara/build-actions/ios@v1`
> 状态：签名链路已用真证书真机验通至导出前最后一环（2026-09-20，见「免费账号限制」）

## 一、工作原理（30 秒版）

你把签名证书（.p12）和描述文件（.mobileprovision）以 base64 形式存进仓库 Secrets；每次 CI 运行时，action 会：

1. 创建**一次性临时 keychain**（随机密码，job 结束即销毁，不碰 runner 的登录钥匙串）；
2. 导入 p12 证书、安装 Apple WWDR 中间证书、安装描述文件（兼容 Xcode 16+ 新目录）；
3. 自动从证书 **OU 字段提取 Team ID**，并与描述文件交叉校验（不一致立即报错并给出指引）；
4. 以手动签名方式 `xcodebuild archive` → `exportArchive` 导出签名 IPA，经 GitHub Artifacts 交付。

Secrets 全程 `::add-mask::` 打码；证书密码只出现在进程命令行，不落盘明文。

## 二、准备签名材料

### 2.1 导出 .p12 证书

在持有证书的 Mac 上：

1. 打开「钥匙串访问」（macOS 15+ 位于 `/System/Applications/Utilities/钥匙串访问.app`，访达按 `Cmd+Shift+G` 粘贴路径前往；启动台里的「密码」App **不是**它）；
2. 左侧选「登录」→ 顶部分类选「我的证书」；
3. 找到你的证书（`Apple Development: xxx` 或 `Apple Distribution: xxx`），**展开确保下面挂着私钥**，右键 → 导出 → 存为 `signing.p12`，设置导出密码（此密码即 `IOS_P12_PASSWORD`）。

### 2.2 获取 .mobileprovision 描述文件

- **付费开发者账号**：到 [developer.apple.com](https://developer.apple.com/account/resources/profiles) 创建/下载**手动管理**的描述文件（App Store / Ad Hoc / Development 均可）；
- 描述文件的 App ID 前缀（Team ID）必须与证书的 OU 一致——CI 会强制校验。

### 2.3 base64 编码

```bash
base64 -i signing.p12 | pbcopy        # → IOS_P12_BASE64
base64 -i xxx.mobileprovision | pbcopy # → IOS_MOBILEPROVISION_BASE64
```

## 三、配置仓库 Secrets

仓库 → **Settings → Secrets and variables → Actions**，添加 3 个：

| Secret 名 | 内容 |
|---|---|
| `IOS_P12_BASE64` | .p12 的 base64 |
| `IOS_P12_PASSWORD` | .p12 导出密码 |
| `IOS_MOBILEPROVISION_BASE64` | .mobileprovision 的 base64 |

## 四、配置 workflow

```yaml
name: iOS Sign Release

on:
  workflow_dispatch:

jobs:
  build-sign:
    runs-on: [macos, arm64, macrunara]
    timeout-minutes: 30

    steps:
      - uses: actions/checkout@v4

      - uses: macrunara/setup-action@v1
        with:
          installation-id: ${{ secrets.MACRUNARA_INSTALLATION_ID }}
          region: auto

      - name: Build Signed IPA & Upload
        uses: macrunara/build-actions/ios@v1
        with:
          scheme: MyApp
          project: MyApp.xcodeproj        # workspace 工程填 .xcworkspace 路径
          configuration: Release
          sdk: iphoneos
          distribution: development       # 见下方取值表
          sign_p12_base64: ${{ secrets.IOS_P12_BASE64 }}
          sign_password:   ${{ secrets.IOS_P12_PASSWORD }}
          mobileprovision_base64: ${{ secrets.IOS_MOBILEPROVISION_BASE64 }}
          upload_artifact: true
          artifact_name: ios-signed-ipa
          artifact_path: build/Release-iphoneos
```

### distribution 取值

| 值 | 签名方式 | 说明 |
|---|---|---|
| `none`（默认） | 不签名 | 历史行为，老 workflow 零影响 |
| `development` | Development 证书 | 开发测试包 |
| `local` | → ad-hoc | 本地/内测分发 |
| `pgyer` / `firebase` | → ad-hoc | 上传分发暂缓，IPA 走 Artifacts |
| `testflight` | → app-store | 上传分发暂缓，IPA 走 Artifacts |

签名 IPA 统一在 Actions → run 页面底部 **Artifacts** 下载。

## 五、验证签名

构建日志出现 `签名环境就绪：TEAM_ID=XXXXXXXXXX ...` 即材料校验通过。进一步核验：

```yaml
      - name: Verify signature
        run: |
          APP=$(find . -maxdepth 5 -path "*.xcarchive/Products/Applications/*.app" -print -quit)
          codesign -dv --verbose=2 "$APP" 2>&1 | grep -E '^(Identifier|Authority|TeamIdentifier)'
```

`Authority` 应为你的证书名，`TeamIdentifier` 应为你的 Team ID。

## 六、免费 Apple ID（Personal Team）限制 ⚠️

用免费账号可以做**链路验证**，但**无法通过 CI 导出签名 IPA**：

- 免费账号的描述文件由 Xcode 自动托管（Xcode managed），苹果政策**禁止**用于手动签名，archive 会报：
  `Provisioning profile "..." is Xcode managed, but signing settings require a manually managed profile.`
- 免费证书/描述文件 **7 天过期**，Secrets 需频繁更换；
- 结论：正式使用请配付费开发者账号（$99/年）的证书 + 手动管理描述文件。免费账号下如需出包，可在 Mac 上 Xcode GUI 自动签名 Archive（只能装在已注册设备上）。

## 七、常见问题

**Q：报 `证书 Team（AAA）与描述文件 Team（BBB）不一致`？**
A：p12 和 mobileprovision 来自不同 Apple 团队。Team ID 以证书 subject 的 **OU 字段**为准（Personal Team 证书 CN 括号里是个人 ID，不是 Team ID）。重新导出/生成同一团队的材料。

**Q：报 `keychain 内无有效签名身份（0 valid identities）`？**
A：p12 里证书和私钥不配对（导出时没选中带私钥的证书项），或 WWDR 中间证书缺失。重新从「我的证书」里**展开带私钥的那一项**导出。

**Q：报找不到描述文件 / profile not found？**
A：确认 base64 是单行；确认描述文件未过期；确认 bundle id 与描述文件的 App ID 一致。

**Q：Flutter / React Native 的 iOS 工程怎么签？**
A：`macrunara/build-actions/flutter@v1`、`/rn@v1` 的 iOS 侧复用本链路，提供相同的 3 个签名 inputs + `distribution`，行为一致（先 no-codesign 构建，再手动签名 archive 导出 IPA）。

**Q：怀疑 runner 跑的是旧版 action？**
A：self-hosted runner 按 ref 名缓存 action。把 `uses:` 里的 `@v1` 临时改成完整 commit SHA 可强制绕过缓存；定位后改回 `@v1`。
