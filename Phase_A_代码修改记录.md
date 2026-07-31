# Phase A 代码修改记录

> 日期：2026-07-29
> 范围：Phase A（替换 ASR：Vosk/Google/flutter_sound → Sherpa-ONNX + Kotlin 原生层）
> 指导文档：《项目总体规划.md》v1.1 第十节 Phase A（A-1 ~ A-8）
> 约束：不动翻译逻辑（Phase B）、不动 TTS 队列（Phase C）；每步独立可运行

---

## 修改总览

| 类别 | 文件数 | 说明 |
|------|--------|------|
| 新建 | 12 | android/ 平台工程 7 文件 + Dart 2 文件 + CI 2 文件 + libs/README |
| 重写 | 5 | pubspec.yaml, live_session.dart, live_page.dart, settings_page.dart, BUILD.md |
| 改造 | 3 | app_settings.dart, translation_service.dart, .gitignore |
| 重写 CI | 2 | build-apk.yml, codemagic.yaml |
| 删除 | 5 | speech_engine.dart, vosk_engine.dart, google_engine.dart, download_models.sh, assets/*.zip(3) |

---

## A-1: pubspec.yaml 解锁 Dart 3 + 删旧依赖

**文件**: `pubspec.yaml`

| 项 | 修改前 | 修改后 | 原因 |
|----|--------|--------|------|
| sdk | `>=2.17.0 <3.0.0` | `>=3.3.0 <4.0.0` | 移除 vosk_flutter 后解锁 Dart 3 / Flutter 3.22+ |
| vosk_flutter | `^0.3.48` | **删除** | 全面转向 Sherpa-ONNX |
| flutter_sound | `9.2.13` | **删除** | 麦克风采集改由 Kotlin AudioRecord |
| speech_to_text | `6.1.1` | **删除** | Google 引擎移除 |
| http | `^0.13.5` | `^1.2.0` | Dart 3 兼容版本 |
| flutter_tts | `3.8.5` | `^4.0.0` | Dart 3 兼容版本 |
| shared_preferences | `2.2.2` | `^2.3.0` | Dart 3 兼容版本 |
| permission_handler | `10.2.0` | `^11.3.0` | Dart 3 兼容版本 |
| flutter_lints | `^2.0.0` | `^4.0.0` | Dart 3 兼容版本 |
| assets 段 | 3 个 vosk zip | **删除** | 模型改由 android/app/src/main/assets/ 打包 |
| sherpa_onnx | — | **不加** | 底座走 libs/ AAR，避免双源 |
| version | `1.0.0+1` | `2.0.0+1` | 大版本升级 |
| description | 旧描述 | 更新为双语对话翻译器 | 定位变更 |

**删除的文件**:
- `assets/models/vosk-model-small-en-us-0.15.zip`
- `assets/models/vosk-model-small-cn-0.22.zip`
- `assets/models/vosk-model-small-ru-0.22.zip`
- `tools/download_models.sh`（被 `tools/fetch_models.sh` 替代）

---

## A-2: android/ 平台工程

**新建文件**（全部为文本，可入库；`gradle-wrapper.jar` 为二进制由 `flutter create` 生成、.gitignore 忽略）:

### `android/settings.gradle`
- Flutter 3.22+ plugin management DSL
- AGP 8.1.0, Kotlin 1.9.0

### `android/build.gradle`
- 根项目构建文件，仓库 google() + mavenCentral()

### `android/gradle.properties`
- JVM 内存 4G, AndroidX, 并行构建

### `android/gradle/wrapper/gradle-wrapper.properties`
- Gradle 8.3（配合 AGP 8.1.0）

### `android/app/build.gradle` ⭐ 关键
- `namespace = "com.example.my_translate"`
- `compileSdk = 34`, `minSdk = 23`（sherpa-onnx 要求 23+）
- `ndk { abiFilters 'arm64-v8a' }` 单架构
- `androidResources { noCompress 'onnx' }` 模型不压缩
- `implementation files("libs/sherpa-onnx-1.12.14.aar")` **不走 Maven**（INV-MIRROR）

### `android/app/src/main/AndroidManifest.xml`
- 权限：RECORD_AUDIO + INTERNET + ACCESS_NETWORK_STATE
- **删除** Google RecognitionService `<queries>`（S5 残留清理）
- 新增 TTS_SERVICE `<queries>`（flutter_tts 需要）
- MainActivity 使用 embedding v2

### `android/app/proguard-rules.pro`
- sherpa-onnx / onnxruntime 保留规则

### `android/app/src/main/kotlin/com/example/my_translate/MainActivity.kt`
- 继承 `io.flutter.embedding.android.FlutterActivity`（v2）
- `configureFlutterEngine` 中注册 `AsrPlugin`

### `android/app/libs/README.txt`
- AAR 下载说明占位

### `.gitignore` 修改
- `/android/` 整体忽略 → 改为仅忽略生成物（local.properties, .gradle/, build/, gradle-wrapper.jar, assets/models/）
- 新增模型目录忽略：`/android/app/src/main/assets/models/`

---

## A-3: 模型下载脚本

**新建文件**: `tools/fetch_models.sh`

| 修改前 | 修改后 |
|--------|--------|
| `tools/download_models.sh`：从 alphacephei.com 下载 Vosk 模型 | `tools/fetch_models.sh`：从 **ModelScope 镜像**下载 Sherpa-ONNX 模型 |

下载源（INV-MIRROR）:
- silero_vad.onnx → ModelScope `zhaochaoqun/sherpa-onnx-asr-models`
- bilingual zh-en int8 → ModelScope `pkufool/sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20`
- T-one 俄语 → 同全量镜像仓（若未同步则提示手动下载）
- **禁止 github.com 下载源**（脚本内无任何 GitHub URL）

---

## A-4: Kotlin ASR 层 7 文件

全部位于 `android/app/src/main/kotlin/com/example/my_translate/asr/`

### `AsrConfig.kt`
- 参数集中地：VAD 阈值、采集帧长、字符集判定比例、推理线程数
- `fromMap()` 支持 Dart setConfig 热更新
- `frameSamples` 计算属性 = sampleRate * frameMs / 1000

### `SherpaRecognizer.kt`
- 单识别器包装，统一 transducer（bilingual）与 CTC（T-one 俄语）差异
- `buildConfig()` 按 ModelType 构造 OnlineRecognizerConfig
- 接口：`feed(FloatArray)` / `decode()` / `partialText` / `isEndpoint()` / `finalizeSegment()` / `reset()` / `decodeBuffer(FloatArray)`（兜底重解码用）
- `enableEndpoint = true`，`rule1MinTrailingSilence = 0.8f`（与 VAD 对齐）

### `RecognizerManager.kt`
- 按模式加载：zhEn → bilingual ×1；zhRu → {bilingual, russian} 双加载单活跃
- `copyAssetDir()`：assets → 内部存储（sherpa-onnx 需文件路径）
- `onFrame()`：喂活跃识别器 → decode → endpoint 检测 → partial/final emit
- `onVadSegmentEnd()`：VAD 判定句末 → finalize
- `onSegmentEnd()`：模式 A 直接上抛；模式 B charMatch 校验（Phase A 失败也上抛，Phase D 才启用重解码）
- `setActiveLang()`：模式 B 手动 Chip 切换活跃识别器 + reset
- `charMatch()`：字符集统计（CJK/西里尔/拉丁），机械规则不含语义

### `VadProcessor.kt`
- 包装 sherpa-onnx `Vad` + `SileroVadModelConfig`
- `process(FloatArray)`：feed + 检查完整段输出 → onSegmentEnd 回调
- `flush()`：强制冲刷（stop 时调用）
- Phase A：VAD 与 ASR endpoint 互补；Phase D：启用 VAD 门控省电

### `AudioCapture.kt`
- `AudioRecord`，`VOICE_RECOGNITION` 源，16000Hz / MONO / PCM_16BIT
- 独立 audio 线程，每 frameMs（100ms = 1600 samples）一帧
- PCM16 → FloatArray（/32768f 归一化）
- `bufferSize = max(minBuf, frameBytes * 4)`

### `AudioSessionManager.kt`
- 生命周期总控：幂等 start/stop、HandlerThread（inference）管理
- 线程模型：audio 线程 → inference HandlerThread（VAD+ASR 串行）→ mainHandler emit
- `start(mode)`：权限校验 → 创建 inference 线程 → 加载模型 → 启动采集
- `stop()`：停采集 → flush VAD → flushLast ASR → 释放 → 关线程
- 异常捕获 → emit error → 自动 stop

### `AsrPlugin.kt`
- Channel 边界：MethodChannel "asr/control" + EventChannel "asr/events"
- embedding v2 注册（`FlutterEngine.dartExecutor.binaryMessenger`）
- 所有 emit 经 `mainHandler.post` 切主线程
- `onCancel` 只断 sink 不停会话（防热重载误停）
- JSON 编解码（`JSONObject`）

---

## A-5: Dart 新文件 + 删旧

### 新建 `lib/services/speech/native_asr_engine.dart`
- 替代旧 `speech_engine.dart` / `vosk_engine.dart` / `google_engine.dart` 三文件
- `AsrEvent`：type/text/langSwitched
- `NativeAsrEngine`：MethodChannel + EventChannel 封装
- `subscribe()` / `unsubscribe()`：EventChannel 订阅管理
- broadcast Stream，多监听者安全

### 新建 `lib/services/translation_router.dart`
- 全 App 语言判定**唯一**语义实现（INV-BOUNDARY）
- `SrcLang` 枚举：zh / en / ru
- `RouteResult`：source + target
- `route(text, mode, {manualLang})`：手动优先 > 字符集自动判定
- `targetOf(source, mode)`：模式表定方向（zhEn: zh→en, en→zh；zhRu 同理）
- `_detectByCharset()`：CJK / 西里尔 / 拉丁 主导判定（charDominance=0.6）
- 纯函数，可单元测试

### 删除
- `lib/services/speech/speech_engine.dart`
- `lib/services/speech/vosk_engine.dart`
- `lib/services/speech/google_engine.dart`

---

## A-6: live_session.dart 精简重写 + app_settings.dart 字段迁移

### `lib/services/live_session.dart`（大幅重写）

| 修改前 | 修改后 | 原因 |
|--------|--------|------|
| 导入 speech_engine/vosk_engine/google_engine | 导入 native_asr_engine + translation_router | 引擎替换 |
| SpeechEngine? _engine | NativeAsrEngine _engine（直接实例化） | 无抽象基类（YAGNI） |
| _streamBuffer / _streamLang | **删除** | 切句移交原生 VAD |
| _punctTimer / _punctBusy / _lastPunctCall | **删除** | 标点由翻译 Prompt 处理（S2/S6 消亡） |
| _silenceTimer / _kCommitMs | **删除** | 切句移交原生 VAD |
| _kPunctDebounceMs / _kPunctMaxIntervalMs | **删除** | 同上 |
| _kMaxChars / _kMaxWords | **删除** | 同上 |
| _recentSources / _fillers / _isMeaningless | **删除** | 上下文窗口 + 语气词过滤不再需要 |
| _onSegment / _runPunct / _armPunctTimer / _armSilenceTimer / _onSilence / _flushStream | **删除** | 全部切句逻辑移交 Kotlin |
| _manualLang: String? | _manualLang: String ('auto') | 两种模式均有 Chip（INV-MANUAL） |
| _partialLang | **删除** | Kotlin 不上抛 partial 语种 |
| — | _stickyLang: String | 字符集模糊时兜底 |
| start(): 创建 Vosk/Google 引擎 → initialize → start | start(): permission → engine.subscribe → engine.start(mode) | 新引擎 |
| _handleFinal(text, lang, speak): 标点+翻译+TTS | _handleFinal(text): route → translate(source,target,text) → 分发 | 路由+翻译+INV-TTS |
| setManualLang: Vosk preferredLang | setManualLang: 模式 B 下发 engine.setActiveLang | 新引擎 |
| — | setMode(String): stop → settings.setMode → reset | 模式切换 |
| stop(): 计时器取消 → engine.stop → tts.stop → flushStream(speak:false) | stop(): engine.stop → engine.unsubscribe → tts.stop | 简化（Kotlin 侧 flush） |

**保留**：SessionStatus 枚举、NoteEntry、`_notes = [..._notes, e]` 不可变更新、Selector 友好 getters

### `lib/services/app_settings.dart`（改造）

| 修改前 | 修改后 | 原因 |
|--------|--------|------|
| _engine / _kEngine / setEngine / engine getter | **删除** | 不再有引擎选择 |
| _modelBaseUrl / _kModelBase / setModelBaseUrl / modelBaseUrl | **删除** | 不再运行期下载模型 |
| _foreignLang ('en'/'ru') | _mode ('zhEn'/'zhRu') | 模式升级 |
| _kForeignLangLegacy | 新增（迁移用） | en→zhEn, ru→zhRu 自动迁移 |
| — | _streamEnabled / _kStreamEnabled / setStreamEnabled | Phase B 预留 |
| _migrateForeignLang() | 新增 | 旧版数据迁移 |

**保留**：llmPresets, llmProvider/llmApiKey/llmModel/ttsRate/fontSize 及其 setter

### `lib/services/translation_service.dart`（改造）

| 修改前 | 修改后 | 原因 |
|--------|--------|------|
| `translate(text, {source, target, isSpeech, context})` | `translate(source, target, text)` | 签名简化（规划 7.3） |
| `punctuate(text, lang)` | **删除** | S2/S6 消亡 |
| context 参数 | **删除** | _recentSources 已删 |
| isSpeech 参数 | **删除**（内部恒为 true） | 语音同传场景固定 |
| _chat() | 保留（Phase 1 成果） | 连接复用+超时 |
| _looksLikeHallucination() | 保留 | 防幻觉 |
| Prompt | 保留英文版（Phase B 换同传模板） | A-6 不动 Prompt |

---

## A-7: UI 页面重写

### `lib/pages/live_page.dart`（重写）

| 修改前 | 修改后 | 原因 |
|--------|--------|------|
| 无模式卡片 | 顶部两枚模式卡片（中⇄英 / 中⇄俄） | 双语对话翻译器定位 |
| _StatusView(status, statusText, partialLang) | _StatusView(status, statusText) | partialLang 已删 |
| 模式 B 才显示 Chip | **两种模式均显示 Chip**（INV-MANUAL） | 用户批注 |
| Chip: 自动/中文/外语(foreignLang) | Chip: 自动/中文/外语(mode=='zhRu'?'ru':'en') | 模式驱动 |
| settings.foreignLang | settings.mode | 字段迁移 |
| Selector<LiveSession, String> partialLang | **删除** | 不再有 partialLang |
| partial 预览无前缀 | "正在听: $partial" | 更明确（INV-PARTIAL） |
| _langLabel() | **删除** | 不再需要 |

**保留**：Selector 局部刷新、scrollController 监听、模式卡片 `_ModeCard` 组件

### `lib/pages/settings_page.dart`（改造）

| 修改前 | 修改后 | 原因 |
|--------|--------|------|
| 外语选择 RadioListTile（英文/俄语） | 显示当前模式文字（主页切换） | 模式切换移到主页 |
| 识别引擎 RadioListTile（Vosk/Google） | **删除** | 引擎固定 |
| Google 警告 | **删除** | Google 引擎移除 |
| 自定义模型地址 TextField | **删除** | 不再运行期下载 |
| _modelBaseController | **删除** | 同上 |
| — | 流式翻译 SwitchListTile | Phase B 预留 |

**保留**：供应商/Key/模型/语速/字号

### `lib/main.dart` — 无修改
### `lib/app.dart` — 无修改
### `lib/services/tts_service.dart` — 无修改（Phase C 才改）

---

## A-8: CI + BUILD.md

### `.github/workflows/build-apk.yml`（重写）

| 修改前 | 修改后 | 原因 |
|--------|--------|------|
| Flutter 3.7.12 (Dart 2.19) | Flutter stable (Dart 3) | 解锁 |
| flutter create + sed 补丁 | flutter create + git checkout 恢复自定义文件 | 平台工程入库 |
| — | AAR 下载步骤（若 libs/ 缺失） | INV-MIRROR |
| — | fetch_models.sh (ModelScope) | 模型下载 |
| publish Vosk models to Release | **删除** | 不再用 Vosk |
| sed minSdk=21 | minSdk=23（build.gradle 已配） | sherpa-onnx 要求 |
| android-33 | android-34 | compileSdk 升级 |

### `codemagic.yaml`（重写）
- 同步 GitHub Actions 逻辑

### `BUILD.md`（重写）
- 新增前置下载清单（〇节）
- flutter 3.22+ 环境
- AAR 手动下载步骤
- fetch_models.sh 模型下载
- CI 说明更新

---

## 不变量验证

| 编号 | 验证 |
|------|------|
| INV-TTS | ✅ live_session.dart _handleFinal: source==zh → speak; else → notes only |
| INV-PARTIAL | ✅ live_session.dart _onAsrEvent: partial → _partial 预览; final → _handleFinal |
| INV-SENT | ⏳ Phase C 实现（Phase A 不动 TTS 链路） |
| INV-PROMPT | ⏳ Phase B 换同传模板 |
| INV-OFFLINE | ✅ 模型在 android/app/src/main/assets/，Kotlin AssetManager 直读 |
| INV-BOUNDARY | ✅ Kotlin 只做采集/VAD/推理/charMatch；翻译方向在 Dart TranslationRouter |
| INV-STREAM-FALLBACK | ⏳ Phase B 实现 |
| INV-PRIORITY | ✅ 全程遵循 |
| INV-NOCAL | ✅ 无标定/融合/状态机 |
| INV-MANUAL | ✅ 两种模式均有 Chip，手动 > 自动 |
| INV-MIRROR | ✅ fetch_models.sh 只走 ModelScope；AAR 走 libs/ 入库 |

---

## 已知遗留 / Phase B+C 待办

1. **Phase B**：`translateStream()` SSE + 删除 `punctuate` 残余（已删）+ Prompt 换同传模板
2. **Phase C**：`SentenceSegmenter` + `TtsQueue`（当前 TTS 为直接 speak，非阻塞队列）
3. **Phase D**：模式 B charMatch 兜底重解码（当前留桩直接上抛）
4. **AAR 未入库**：`android/app/libs/` 目前只有 README.txt，用户需手动下载 AAR 并提交
5. **gradle-wrapper.jar 未入库**：二进制文件由 `flutter create` 生成，.gitignore 忽略
6. **模型未下载**：需用户运行 `bash tools/fetch_models.sh` 下载到 assets/models/
7. **无 Flutter SDK 验证**：本沙箱无 Flutter SDK，所有验证靠静态审查 + CI 云端构建 + 用户真机验收
