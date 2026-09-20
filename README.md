# Macrunara Build Actions

> 快速开始与 workflow 模板：https://github.com/macrunara/quickstart

Macrunara Mac CI 集群（Apple Silicon M4）的**四技术栈构建动作**集合。单仓四子目录，每个子目录是一个独立的 Composite Action，统一用 `@v1` tag 引用。

| Action | 引用 | 干什么 |
|--------|------|--------|
| iOS 原生 | `macrunara/build-actions/ios@v1` | xcodebuild 构建 / 归档导出 IPA / 产物上传 |
| Android | `macrunara/build-actions/android@v1` | Gradle Wrapper 构建 / 单测 / APK·AAB 上传 |
| Flutter | `macrunara/build-actions/flutter@v1` | pub get → analyze → test → build ipa（无签名）/ apk |
| React Native | `macrunara/build-actions/react-native@v1` | npm·yarn 安装 → pod install → jest → xcodebuild / gradlew |

## 节点预装环境（macos-mobile v1.2 镜像）

所有 action 默认**直接使用节点预装环境**，不重复安装（每个 job 省 3~8 分钟）：

| 环境 | 版本 | 锁定其他版本 |
|------|------|--------------|
| Xcode | 26.x + CLT | — |
| Flutter SDK | 3.47.2 stable | 传 `flutter-version` 走 `subosito/flutter-action@v2` |
| Android SDK | API 35 + build-tools 35.0.0 + NDK 27.0.12077973 | job 内 `sdkmanager` 补装 |
| JDK | temurin 17.0.20 | 传 `java-version` 走 `actions/setup-java@v4` |
| Node.js | 20.18.0 LTS + yarn 1.22.22 | 传 `node-version` 走 `actions/setup-node@v4` |
| CocoaPods | 1.17.0（bundler 2.4.22） | — |

> 预装工具的 PATH（`~/flutter/bin`、`/usr/local/bin`、系统 gem bin）由各 action 启动时
> 自动写入 `$GITHUB_PATH`，job 内后续 step 无需手动 export。

## 用法速览

### iOS 原生

```yaml
- uses: macrunara/build-actions/ios@v1
  with:
    scheme: MyApp
    project: MyApp.xcodeproj        # 可选；.xcworkspace 同样传这个参数
    configuration: Release
    sdk: iphoneos
    upload_artifact: true
    artifact_path: build/Release-iphoneos
```

#### 签名构建（V1.1-2.1，可选）

默认 `distribution: none` 为免签名构建（行为与旧版完全一致）。传入签名材料后自动切换为
**手动签名 archive → 导出签名 IPA**，IPA 以 `<artifact_name>-signed-ipa` 上传 Artifacts：

```yaml
- uses: macrunara/build-actions/ios@v1
  with:
    scheme: MyApp
    distribution: local                          # none | local | pgyer | testflight | firebase | development
    sign_p12_base64: ${{ secrets.IOS_P12_BASE64 }}
    sign_password: ${{ secrets.IOS_P12_PASSWORD }}
    mobileprovision_base64: ${{ secrets.IOS_MOBILEPROVISION_BASE64 }}
```

- `local/pgyer/firebase` → 导出 `ad-hoc` IPA；`testflight` → 导出 `app-store` IPA；
  `development` → 导出 `development` IPA（开发证书 / 免费 Apple ID Personal Team 场景）
- ⚠️ pgyer / testflight / firebase 的**上传分发暂缓**（第 3 批冻结），目前统一经 Artifacts 交付签名 IPA
- secrets 准备（在 Mac 上执行）：
  `base64 -i signing.p12 | pbcopy`、`base64 -i profile.mobileprovision | pbcopy`（单行 base64）
- 安全：证书/密码全程 `::add-mask::` 脱敏；keychain 为一次性临时文件，随 VM 销毁
- Flutter / React-Native 的 iOS 签名已复用本链路（见对应小节）
- 📖 完整配置指南（证书导出 / 免费 Apple ID 限制 / FAQ）：[docs/iOS签名构建配置指南.md](docs/iOS签名构建配置指南.md)

### Android

```yaml
- uses: macrunara/build-actions/android@v1
  with:
    task: assembleDebug             # task 不含冒号时自动拼成 :app:assembleDebug
    module: app
    upload_artifact: true
    artifact_path: app/build/outputs/
```

#### 签名构建（V1.1-2.1，可选）

默认不传签名材料时行为与旧版完全一致。传入 keystore 后，通过
**Gradle init.d 零侵入注入**（不改客户工程的 build.gradle）为所有名字含
`release` 的 buildType 挂上 `signingConfigs.macrunaraCi`，执行
`assembleRelease` / `bundleRelease` 即产出签名 APK/AAB：

```yaml
- uses: macrunara/build-actions/android@v1
  with:
    task: assembleRelease
    sign_keystore_base64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
    keystore_password:    ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
    key_alias:            ${{ secrets.ANDROID_KEY_ALIAS }}
    key_password:         ${{ secrets.ANDROID_KEY_PASSWORD }}
```

- secrets 准备：`base64 -i my.keystore | pbcopy`（单行 base64，Windows 用 `certutil -encode` 后去头尾行）
- keystore 解码到 `$RUNNER_TEMP`（0600 权限），随 VM 销毁；密码不落任何文件，经环境变量传入
- 只覆盖 release 系 buildType；debug 构建不受影响，四件材料缺一即报错（::error::）
- 📖 完整配置指南（keystore 生成 / 多 module·flavor / FAQ）：[docs/Android签名构建配置指南.md](docs/Android签名构建配置指南.md)

### Flutter

```yaml
- uses: macrunara/build-actions/flutter@v1
  with:
    platform: all                   # ios | android | all
    build-mode: release             # debug | release
    run-tests: 'true'               # analyze + test，可关
    upload_artifact: true           # 上传 build/ios/ipa/ 与 build/app/outputs/flutter-apk/
```

签名构建（可选，复用 iOS / Android 两条链路）：

```yaml
- uses: macrunara/build-actions/flutter@v1
  with:
    platform: all
    build-mode: release
    # iOS 签名四件（同 iOS 原生）；ios-workspace/ios-scheme 默认可自动识别
    sign_p12_base64: ${{ secrets.IOS_P12_BASE64 }}
    sign_password: ${{ secrets.IOS_P12_PASSWORD }}
    mobileprovision_base64: ${{ secrets.IOS_MOBILEPROVISION_BASE64 }}
    # Android 签名四件（同 Android）
    sign_keystore_base64: ${{ secrets.ANDROID_KEYSTORE_BASE64 }}
    keystore_password: ${{ secrets.ANDROID_KEYSTORE_PASSWORD }}
    key_alias: ${{ secrets.ANDROID_KEY_ALIAS }}
    key_password: ${{ secrets.ANDROID_KEY_PASSWORD }}
```

- iOS 侧：`flutter build ios --no-codesign` → `xcodebuild archive`（手动签名）→ 导出 IPA，
  签名产物在 `build/ios/Exported/` 一并上传；`build-mode: debug` + 签名会强制按 release 编译并给出 ::warning::
- Android 侧：init.d 注入自动生效，无需额外配置

### React Native

```yaml
- uses: macrunara/build-actions/react-native@v1
  with:
    package-manager: npm            # npm | yarn
    ios-workspace: ios/MyApp.xcworkspace   # 留空跳过 iOS 构建
    ios-scheme: MyApp
    # android-task: assembleDebug    # 需要 Android 构建时打开
    run-tests: 'true'               # jest，可关
    upload_artifact: true
```

签名构建（可选）：inputs 与 Flutter 相同（iOS 四件 + Android 四件）。
iOS 侧直接用 `ios-workspace`/`ios-scheme` 做手动签名 archive 并导出 IPA 到
`build/Exported/` 上传；Android 侧同样走 init.d 注入。

完整输入参数见各子目录 `action.yml` 顶部注释。

## 构建产物（Artifacts）下载

四个 action 的 `upload_artifact` 默认开启（`'true'`）。构建完成后，产物在
**Actions → 对应 run 的 Summary 页底部 Artifacts 区块** 下载（zip 包），
GitHub 默认保留 90 天，可在仓库 Settings → Actions → Artifact retention 调整。
若显式传 `upload_artifact: false` 则跳过上传。

## 与旧仓库的关系

- `macrunara/local-mac-runner-action` 已迁入本仓库 `ios/` 子目录，**inputs 完全不变**；
  旧仓库 `@v1` tag 保留可用但不再更新（README 有迁移声明）。
- `macrunara/setup-action` 是入口层（品牌横幅 / 参数校验 / region 导出），四类项目通用，继续保留。

用户侧心智模型：**`setup-action` 开头（可选）+ `build-actions/<技术栈>` 干活**。

## 测试

每个 action 带零依赖 bash 单测（mock 对应构建工具，断言脚本行为），任意装有 bash 的环境可跑：

```bash
bash ios/tests/run_tests.sh
bash android/tests/run_tests.sh
bash flutter/tests/run_tests.sh
bash react-native/tests/run_tests.sh
```

仓库 CI（`.github/workflows/test.yml`）在 ubuntu-latest 上对四个 action 做 YAML 语法校验 + 单测，无需真实 macOS Runner。

## 版本标签

商业引用使用 tag，不要直接用 `@main`。发布负责人手动维护：

```bash
git tag -a v1 -m "build-actions v1: ios/android/flutter/react-native"
git push origin v1
```

后续更新发 `v1.x` 补丁并移动 `v1`，破坏性变更升 major。
