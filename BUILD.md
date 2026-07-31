# 构建与安装（Android）— Phase A: Sherpa-ONNX 重构版

## 0. 前置下载清单（动码前先备齐）

> **2026-07-31 修订：模型与 AAR 统一用 `tools/fetch_models_github.sh`（GitHub 官方源）下载。**
> 本地运行需开 VPN；CI（GitHub Actions / Codemagic 海外机）直连即可。
> 原 ModelScope 版 `tools/fetch_models.sh` 因直链 404 已弃用（入口直接报错退出）。

| # | 资源 | 实际体积 | 放置位置 | 入 git |
|---|------|----------|----------|--------|
| 1 | `sherpa-onnx-1.12.14.aar` | ~39MB | `android/app/libs/` | **是**（已入库） |
| 2 | `silero_vad.onnx` | ~2MB | `android/app/src/main/assets/models/vad/` | 否 |
| 3 | bilingual zh-en int8 四件套（官方压缩包 ~488MB，只提取 int8） | ~190MB | `android/app/src/main/assets/models/zh_en/` | 否 |
| 4 | T-one 俄语（官方仅 fp32 `model.onnx`，无 int8） | ~138MB | `android/app/src/main/assets/models/ru/` | 否 |

一键下载（含断点续传，可重复运行增量跳过）：

```bash
# 本地：先开 VPN；若走本地代理端口，按需先 export https_proxy=...
bash tools/fetch_models_github.sh
```

## 1. 前置环境

- **Flutter SDK 3.22+（Dart 3.3+）**：https://docs.flutter.dev/get-started/install
  > Phase A 移除了 vosk_flutter，不再锁 Dart 2.19，用最新稳定版即可。
- **Android SDK**（Android Studio SDK Manager），配置 `ANDROID_HOME`
- 接受许可：`flutter doctor --android-licenses`
- 手机开启「开发者选项 → USB 调试」

验证：`flutter doctor`

## 2. 生成平台工程（仅需一次）

android/ 的文本文件（build.gradle / Manifest / Kotlin）已入库，但 `gradle-wrapper.jar` 等二进制文件需要生成：

```bash
flutter create --platforms=android --project-name my_translate .
```

生成后，恢复我们入库的自定义文件（flutter create 可能覆盖它们）：

```bash
git checkout -- android/app/build.gradle \
  android/app/src/main/AndroidManifest.xml \
  android/app/src/main/kotlin/ \
  android/settings.gradle android/build.gradle \
  android/gradle.properties \
  android/gradle/wrapper/gradle-wrapper.properties \
  android/app/proguard-rules.pro
```

## 3. 下载模型与 AAR

```bash
bash tools/fetch_models_github.sh
```

- 模型落到 `android/app/src/main/assets/models/`（.gitignore 忽略，不入库）。
- AAR 落到 `android/app/libs/`（**已随仓库提交**，脚本检测到已存在会跳过）。
- 压缩包缓存在 `tools/.cache/`（.gitignore 忽略），确认无误后可删。

## 4. 构建与安装

```bash
flutter pub get
flutter build apk --debug
flutter install
```

或把 `build/app/outputs/flutter-apk/app-debug.apk` 拷到手机手动安装。

## 5. 使用说明

- **两种模式**：中⇄英（默认）/ 中⇄俄。主页面顶部卡片切换。
- **手动语种 Chip**：两种模式均显示「自动 / 中文 / 外语」。模式 A 的 Chip 只影响翻译方向；模式 B 的 Chip 还切换 ASR 识别器。
- 听外语 → 中文大字幕（静音）；听中文 → 手机朗读外语译文（同声传译）。
- **翻译后端**：在「设置」选供应商（智谱 GLM / 通义千问 / 豆包），粘贴 API Key。

## 6. 云端构建

### GitHub Actions
push 到 main 分支即自动构建。Artifacts 下载 `my-translate-debug` 里的 `app-debug.apk`。

### CodeMagic
读取 `codemagic.yaml`，Start new build 即可。

> CI 流程：flutter create 补 wrapper → git 恢复自定义文件 → `fetch_models_github.sh` 拉模型（AAR 已入库自动跳过；GitHub Actions 对模型目录做了 cache，二次构建免下载）→ build。

## 7. 备注

- ASR 全离线（模型打进 APK，约 330MB 模型 + 运行库，APK 预计 ~370–390MB），运行期不联网。
- 翻译需联网（LLM API）。
- 若开启代码混淆，`proguard-rules.pro` 已含 sherpa-onnx / onnxruntime 保留规则。
