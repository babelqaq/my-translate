# 构建与安装（Android）— Phase A: Sherpa-ONNX 重构版

## 0. 前置下载清单（动码前先备齐）

> **铁律：模型只从 ModelScope 下载，不从 GitHub Releases 拉取（国内网络必然失败）。**
> AAR 从 GitHub Releases 浏览器直下（见下表）。

| # | 资源 | 下载地址 | 放置位置 | 入 git |
|---|------|----------|----------|--------|
| 1 | `sherpa-onnx-1.12.25.aar`（~38MB） | https://github.com/k2-fsa/sherpa-onnx/releases （资产 `sherpa-onnx-1.12.25.aar`，勿选 -rknn） | `android/app/libs/` | **是** |
| 2 | `silero_vad.onnx`（~2MB） | https://modelscope.cn/models/zhaochaoqun/sherpa-onnx-asr-models | `android/app/src/main/assets/models/vad/` | 否 |
| 3 | bilingual zh-en int8（~80MB） | https://modelscope.cn/models/pkufool/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20 | `android/app/src/main/assets/models/zh_en/` | 否 |
| 4 | T-one 俄语（~50MB） | 同 #2 镜像仓内检索 `t-one-russian` | `android/app/src/main/assets/models/ru/` | 否 |

- 模型 #2–#4 可用 `bash tools/fetch_models.sh` 一键下载（ModelScope 源）。
- AAR #1 需浏览器手动下载后放入 `android/app/libs/` 并 `git add` 提交（CI 若发现缺失会自动从 GitHub 下载，但本地必须手动）。

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

## 3. 下载模型

```bash
bash tools/fetch_models.sh
```

脚本从 ModelScope 镜像下载 3 个模型到 `android/app/src/main/assets/models/`。已存在则跳过。

## 4. 下载 AAR

浏览器打开 https://github.com/k2-fsa/sherpa-onnx/releases ，下载 `sherpa-onnx-1.12.25.aar`（选最新稳定版，勿选 -rknn 变体），放入 `android/app/libs/`。

建议提交到 git（CI 若发现缺失会自动下载，但本地必须手动）：
```bash
git add android/app/libs/sherpa-onnx-1.12.25.aar
git commit -m "chore: add sherpa-onnx AAR"
```

## 5. 构建与安装

```bash
flutter pub get
flutter build apk --debug
flutter install
```

或把 `build/app/outputs/flutter-apk/app-debug.apk` 拷到手机手动安装。

## 6. 使用说明

- **两种模式**：中⇄英（默认）/ 中⇄俄。主页面顶部卡片切换。
- **手动语种 Chip**：两种模式均显示「自动 / 中文 / 外语」。模式 A 的 Chip 只影响翻译方向；模式 B 的 Chip 还切换 ASR 识别器。
- 听外语 → 中文大字幕（静音）；听中文 → 手机朗读外语译文（同声传译）。
- **翻译后端**：在「设置」选供应商（智谱 GLM / 通义千问 / 豆包），粘贴 API Key。

## 7. 云端构建

### GitHub Actions
push 到 main 分支即自动构建。Artifacts 下载 `my-translate-debug` 里的 `app-debug.apk`。

### CodeMagic
读取 `codemagic.yaml`，Start new build 即可。

> CI 会自动执行 flutter create + 恢复自定义文件 + 下载 AAR（若缺失）+ fetch_models + build。

## 8. 备注

- ASR 全离线（模型打进 APK，约 150–170MB），运行期不联网。
- 翻译需联网（LLM API）。
- 若开启代码混淆，`proguard-rules.pro` 已含 sherpa-onnx / onnxruntime 保留规则。
