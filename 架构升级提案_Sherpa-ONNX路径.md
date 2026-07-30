# 架构升级提案：Silero VAD + Sherpa-ONNX 流式 ASR + GLM 流式翻译 + Kotlin 音频层

> 目标：把当前「Vosk 离线 + Google 在线 + flutter_sound + 非流式双 LLM」管线，升级为
> 「Kotlin 原生音频层 → Silero VAD → Sherpa-ONNX Zipformer 流式 ASR → GLM 流式翻译 → Flutter UI」。
> 以既有 *Project Review.md* 的 ① 准确率 ② 流式 ③ 实时 ④ 简洁 四原则为标尺。
> 本文件只做方案与修改建议，**不改动任何源码**；Phase 1（稳定性/正确性修复）已完成，本方案在其之上推进。

---

## 一、为什么是这条路径（与四原则的对齐）

| 现状痛点（Review 编号） | 新栈如何消解 |
|---|---|
| **S3** ASR 跑在 UI 线程（flutter_sound 回调 + Vosk FFI await） | 音频采集、VAD、ASR 推理全部放进 **Kotlin 原生层**，Dart 主线程只收 `partial/final` 文本事件，彻底离开 UI isolate |
| **S1** 翻译非流式（`stream:false`） | **GLM SSE 流式**：译文逐 token 到达，体感延迟≈首 token 时间 |
| **S2** 每句串行两次 LLM（标点+翻译） | 合并为「一次流式调用，模型直接输出带标点译文」，省一次 RTT |
| **S6** `_runPunct` 与 partial 覆盖的 race（漏内容） | 合并后删掉独立标点请求，race 自然消失 |
| **M4** 双识别器串行 `acceptWaveformBytes` | Kotlin 内对多识别器并行喂帧（`Future`/协程并发） |
| **M5** `_recentSources` 上下文顺序错乱 | 流式翻译按请求序号串行提交 |
| **① 准确率** Vosk 小模型识别率有限 | Zipformer 离线模型识别率显著高于 Vosk small；VAD 切除静音提升边界判定 |
| **② 流式** partial 来自 ASR + 译文来自 LLM 双层流式 | 双流式叠加，体验更接近 ChatGPT Voice |

**关键认知**：Sherpa-ONNX **内置 Silero VAD**（`silero_vad.onnx`），二者是同一原生库的一体两面——并非引入两份重依赖。Kotlin 原生层同时持有 VAD 与 ASR，是最省心也最高效的组合。

---

## 二、目标架构总览

```
麦克风(PCM16@16kHz/单声道)
   │  (Kotlin AudioRecord，后台线程/协程)
   ▼
[ Kotlin 原生层  android/app/.../kotlin/ ]
   ├─ Silero VAD        ：切分语音段，丢弃静音，输出"在场/离开"事件
   ├─ Sherpa-ONNX Zipformer Streaming ASR（按语种各一个 Recognizer）
   │     zh Recognizer ┐
   │     en/ru Recognizer ├─► 置信度语种仲裁（复用现有黏滞+手动提示策略）
   │     (可多实例并行) ┘
   └─ 通过 EventChannel 仅回传文本事件：
        {type:'partial'|'final', text, lang:'zh'|'en'|'ru'}
   ▲
   │  MethodChannel 控制：start(foreignLang, manualLang) / stop() / setManualLang()
   │
[ Dart 侧  lib/ ]
   SherpaAsrEngine 实现现有 SpeechEngine 接口 → onSegment(text,isFinal,lang)
        │
        ▼
   LiveSession（编排：分段/路由/上下文/TTS 调度，已 Phase1 收窄+枚举化）
        │  _handleFinal
        ├─ 外语源 → GLM 流式翻译 Stream<String> → 增量写 NoteEntry.translation（大字幕逐字浮现）
        └─ 中文源 → GLM 流式翻译 → 首 token 即 fire-and-forget 入 TTS 队列（非阻塞）
        │
        ▼
   TtsService 队列化（Phase2 P0，S4）：排队+上限丢弃最旧
        ▼
   Flutter UI（沿用 Phase1 的 Selector 收窄，无需大改）
```

**不变项**：`SpeechEngine` 抽象接口、`LiveSession` 对外状态语义（`notes/status/partial/...`）、
`AppSettings` 注入方式、Flutter UI 结构（Phase 1 已做 Selector 收窄，直接复用）。
这意味着新栈以「替换引擎实现 + 新增原生层」为主，UI 与编排层改动可控。

---

## 三、逐组件改造建议

### 3.1 Android Kotlin 音频与识别层（新增，核心）

新增 `android/app/src/main/kotlin/<pkg>/asr/`：

- **`AudioCapture.kt`**：`AudioRecord` 采集 16kHz/16bit/单声道 PCM，写入环形缓冲；后台线程循环 `read()`。
- **`VadGate.kt`**：用 Sherpa-ONNX 的 `VoiceActivityDetector`（Silero）消费 PCM，产出语音段边界。
  仅在「语音在场」帧喂给 ASR，静音段触发一次 `final` 刷新，降低无效计算与误判。
- **`SherpaAsrHost.kt`**：持有 1~N 个 `OnlineRecognizer`（zh + 外语 en/ru），每帧 `acceptWaveform` +
  `decode`，按 `getResult` 置信度做**语种仲裁**（移植现有 Vosk 的「置信度+黏滞窗口+手动提示」逻辑）。
  通过 `EventChannel` 发射 `partial/final`；通过 `MethodChannel` 接收 `start/stop/setManualLang`。
- **依赖**：在 `android/app/build.gradle` 引入 `sherpa-onnx` AAR（或 `implementation 'com.k2fsa.sherpa.onnx:...'`），
  配置 `minSdk` ≥ 21、`ndk` 版本对齐（Sherpa 预编译 so 多为 arm64-v8a）。

> **决策点 A**：是否自写 Kotlin 全量逻辑，还是以 `sherpa_onnx` Flutter 插件（已带 JNI so）为底座，
> 仅把 AudioRecord+VAD 调度放进 Kotlin？前者最贴合「Kotlin 音频层」诉求且彻底脱离 UI 线程；
> 后者落地更快、避免重编 so。建议：**以插件 so 为底座 + 自写 Kotlin 调度层**（折中，风险最低）。

### 3.2 Dart 侧引擎桥接（新增 `lib/services/speech/sherpa_asr_bridge.dart`）

实现现有 `SpeechEngine` 接口，使 `LiveSession` 零感知底层变化：

```dart
class SherpaAsrEngine implements SpeechEngine {
  final EventChannel _evt = const EventChannel('translator/asr');
  final MethodChannel _ctl = const MethodChannel('translator/asr_ctl');
  StreamSubscription? _sub;
  void Function(String, bool, String)? _onSegment;

  @override
  Future<void> initialize({void Function(String)? onStatus, String? foreignLang}) async {
    await _ctl.invokeMethod('init', {'foreignLang': foreignLang});
  }

  @override
  Future<void> start({required void Function(String, bool, String) onSegment}) async {
    _onSegment = onSegment;
    _sub = _evt.receiveBroadcastStream().listen((e) {
      final m = Map<String, dynamic>.from(e);
      if (m['type'] == 'partial' || m['type'] == 'final')
        _onSegment!(m['text'], m['type'] == 'final', m['lang']);
    });
    await _ctl.invokeMethod('start');
  }

  @override
  Future<void> stop() async {
    await _ctl.invokeMethod('stop');
    await _sub?.cancel();
  }
}
```

`live_session.dart` 中 `start()` 的引擎选择改为 `SherpaAsrEngine()`（按设置可回退 Vosk，便于灰度）。

### 3.3 语种仲裁策略

- **推荐（保准确率）**：沿用现有「外语+中文双/三识别器并行 + 置信度仲裁 + 黏滞 + 手动提示」，
  仅把实现从 Dart/Vosk 移植到 Kotlin/Sherpa。俄语按 `settings.foreignLang` 动态挂载 `ru` 识别器。
- **备选（更简）**：单 multilingual Zipformer 模型直接输出语种。代码更简单，但小语种/中英混说准确率通常弱于双实例。
- 手动语种提示（`manualLang`）经 `MethodChannel` 下发给 Kotlin，直接锁定对应识别器，绕过仲裁。

### 3.4 GLM 流式翻译（改造 `lib/services/translation_service.dart`）

现有 `_chat()` 已走 OpenAI 兼容协议，`llmBaseUrl` 指向 `https://open.bigmodel.cn/api/paas/v4/chat/completions`。
只需新增流式分支（SSE 解析），**无需换供应商、无需改 prompt 体系**：

```dart
Stream<String> translateStream(String text, {
  required String source, required String target,
  bool isSpeech = true, List<String>? context,
}) async* {
  final req = http.Request('POST', Uri.parse(settings.llmBaseUrl))
    ..headers.addAll({'Content-Type':'application/json',
                      'Authorization':'Bearer ${settings.llmApiKey}'})
    ..body = jsonEncode({'model': settings.effectiveModel,
      'messages': _buildMessages(text, source, target, context, isSpeech),
      'temperature': 0.1, 'stream': true});
  final resp = await _client.send(req).timeout(_kRequestTimeout);
  await for (final line in resp.stream
      .transform(utf8.decoder).transform(const LineSplitter())) {
    if (!line.startsWith('data:')) continue;
    final data = line.substring(5).trim();
    if (data == '[DONE]') break;
    final json = jsonDecode(data) as Map<String, dynamic>;
    final delta = json['choices']?[0]?['delta']?['content'] as String?;
    if (delta != null && delta.isNotEmpty) yield delta;   // 逐 token 产出
  }
}
```

- **标点+翻译合一**：system prompt 直接要求「输入 ASR 原文，输出带自然标点的译文」，删除 `punctuate` 独立路径（S2）。
- **保留降级**：网络/流式失败时回退 `_chat()` 一次性翻译；无 Key 时不触发 TTS。
- 沿用 Phase1 已加的 `_client` 复用 + `_kRequestTimeout` 超时；流式版用 `StreamSubscription.cancel()` 支持停止取消。

### 3.5 TTS 非阻塞队列（改造 `lib/services/tts_service.dart`，Phase2 P0/S4）

- 内部 FIFO 队列，`speak()` 不再 `awaitSpeakCompletion(true)` 阻塞调用方；
  中文分支 `_handleFinal` 拿到首 token 即 `tts.enqueue(foreign)` 后继续翻译循环。
- 队列上限 3，超出丢弃最旧未读句；`stop()` 清空队列并取消在途朗读。

### 3.6 Flutter UI（基本不变）

- 直接复用 Phase 1 已完成的 `Selector` 收窄版 `live_page.dart`。
- 仅需确认：`partial` 来自 Kotlin 事件流，频率由 VAD/ASR 决定；`NoteEntry.translation` 改为增量写入，
  UI 用既有的 `Selector<LiveSession, List<NoteEntry>>` 即可自然呈现「逐字浮现」。

### 3.7 设置与模型管理（改造 `app_settings.dart` / `settings_page.dart`）

- 新增：`asrEngine`('sherpa'|'vosk' 灰度)、`vadThreshold`、`foreignLang` 已存在。
- 模型来源二选一（**决策点 B**）：
  - **内置 asset**：把 `encoder/decoder/joiner/tokens.onnx` 随包发布（简单，但 APK 增 50–150MB）；
  - **首次启动下载**：复用现有 `tools/download_models.sh` 思路，改为拉取 onnx 并解压到 `getApplicationDocumentsDirectory()`。
- 翻译供应商默认置为「GLM 流式」；保留多供应商 + 流式开关以兼容弱网降级。

---

## 四、与现有问题清单的对应关系

| 编号 | 问题 | 本方案 |
|---|---|---|
| S1 | 翻译非流式 | ✅ Phase B：GLM SSE 流式 |
| S2 | 串行双 LLM | ✅ Phase B：合并标点+翻译为一次流式 |
| S3 | ASR 在 UI 线程 | ✅ Phase A：全部迁入 Kotlin 原生层 |
| S4 | TTS 阻塞 | ✅ Phase B：非阻塞队列 |
| S5 | codemagic 冲突 | ➖ 已由 Phase 1 修复，维持 |
| S6 | `_runPunct` race | ✅ Phase B：删标点独立请求，race 消失 |
| S7 | `stop()` 顺序 | ➖ 已由 Phase 1 修复，维持 |
| M1/M2 | 整页 rebuild / 滚动回调 | ➖ 已由 Phase 1 修复，维持 |
| M3 | 无超时/连接复用 | ✅ Phase A/B：流式带超时+取消 |
| M4 | 双识别器串行 | ✅ Phase A：Kotlin 并行喂帧 |
| M5 | 上下文顺序错乱 | ✅ Phase B：请求序号串行化 |
| M6/M7/M10 | 枚举/俄语 Chip/中文阈值 | ➖ 已由 Phase 1 修复，维持 |
| M8 | Google 引擎不重置 | ➖ Google 引擎被整体移除 |
| M9 | TTS 状态未用 | ◐ 队列化时可顺手精简 |
| L1–L9 | 死代码/冗余 | ✅ 随 Vosk/Google/flutter_sound 移除一并清理 |
| L10 | 无测试 | ◐ Phase C 补 `StreamSegmenter`/`TranslationService` 单测 |

**结论**：本方案一次性覆盖 S1/S2/S3/S4/S6/M3/M4/M5 等全部严重与多数中等项；Phase 1 已覆盖 S5/S7/M1/M2/M6/M7/M10。
仅 M8/M9 等随引擎替换自然消解或顺手清理。

---

## 五、分阶段实施路线（每阶段独立可运行）

> 前提：Phase 1 已完成。以下 A/B/C 仍遵循「一次一个 Phase、完成即请你确认」的约定。

### Phase A — 原生音频+识别层（直击 S3/M4，先不动翻译）
1. Android 侧：引入 sherpa-onnx，落地 `AudioCapture`+`VadGate`+`SherpaAsrHost`（Kotlin）。
2. Dart 侧：`sherpa_asr_bridge.dart` 实现 `SpeechEngine`，`LiveSession` 切到该引擎。
3. 暂时保留**非流式翻译**，仅验证 ASR 质量与「UI 线程零占用」。
4. 删除 `vosk_engine.dart` / `google_engine.dart` / `flutter_sound` 依赖（灰度期可暂留 Vosk 回退）。
- **验收**：录音期间 UI 滚动/按钮零卡顿（Profiler 验证 UI 线程占用骤降）；中/英/俄识别率较 Vosk 明显提升。

### Phase B — GLM 流式翻译 + TTS 队列（直击 S1/S2/S4/S6/M5）
1. `TranslationService.translateStream` 落地 SSE（3.4）。
2. `LiveSession._handleFinal` 消费 `Stream<String>`：外语源增量写 `NoteEntry.translation`；中文源首 token 入 TTS 队列。
3. 删除 `punctuate` 独立路径与 `_runPunct` 计时器族；上下文窗口按请求序号串行。
4. `TtsService` 队列化（3.5），`stop()` 取消在途流式请求。
- **验收**：英文源译文逐字浮现；连续三句中文不堆积；停止即停、在途流被取消；准确率不降。

### Phase C — 收尾与质量
1. 语种仲裁强化（3.3）、设置页模型管理 UI（3.7）。
2. 模型打包方式定稿（内置 vs 下载）+ codemagic/GH Actions 调整（大模型资源处理）。
3. 补充单测（分段逻辑、SSE 解析、降级路径）；清理死代码。
- **验收**：`flutter analyze` 无 warning；全功能回归；包体与冷启动达标。

---

## 六、受影响文件清单

**新增**
- `android/app/src/main/kotlin/<pkg>/asr/AudioCapture.kt`
- `android/app/src/main/kotlin/<pkg>/asr/VadGate.kt`
- `android/app/src/main/kotlin/<pkg>/asr/SherpaAsrHost.kt`
- `lib/services/speech/sherpa_asr_bridge.dart`

**修改**
- `lib/services/live_session.dart`（引擎注入 + 消费 Stream + 删 punct 计时器）
- `lib/services/translation_service.dart`（新增 `translateStream`）
- `lib/services/tts_service.dart`（队列化）
- `lib/services/app_settings.dart`（asrEngine/vad/模型来源）
- `lib/pages/settings_page.dart`（模型选择/下载 UI）
- `android/app/build.gradle`、`android/build.gradle`（sherpa-onnx 依赖、minSdk、ndk）
- `pubspec.yaml`（移除 `flutter_sound`/`vosk_flutter`/`speech_to_text`；如需纯通道则不加 dart 包）
- `tools/download_models.sh`（换 onnx 模型）
- `codemagic.yaml` / `.github/workflows/build-apk.yml`（模型资源打包）

**删除**
- `lib/services/speech/vosk_engine.dart`、`google_engine.dart`（灰度通过后）
- `flutter_sound` 相关录音代码

---

## 七、关键风险与缓解

| 风险 | 缓解 |
|---|---|
| 模型体积（onnx 多语言 50–150MB）致 APK 过大 | 默认「首次启动下载」；或 Android App Bundle + Play Asset Delivery |
| 自编 Kotlin 层构建链路（NDK/so）复杂 | 以 `sherpa_onnx` 插件预编译 so 为底座，仅自写调度层（决策点 A） |
| 平台通道高频 PCM 延迟 | Kotlin 内**直接喂** Sherpa（同进程），仅回传低频文本事件，文本事件延迟可忽略 |
| GLM 流式依赖网络/费用，弱网断流 | 保留 `_chat()` 非流式降级 + 超时取消；无 Key 不触发 TTS |
| 俄语 Zipformer 模型质量/可用性需实测 | Phase A 即纳入 ru 识别器灰度，先验证再默认开启 |
| 语种仲裁逻辑从 Dart 移植到 Kotlin 易错 | 仲裁策略写单测（Kotlin/JVM 单测或 Dart 侧镜像测试） |

---

## 八、待你确认/决策的问题

1. **是否全面转向 Sherpa-ONNX**，移除 Vosk/Google？离线能力实际**增强**（Zipformer 更强且仍离线），但需重新打包模型。
2. **Kotlin 全量自写 vs 插件底座+自写调度层**（决策点 A）？影响工作量与构建风险。
3. **语种仲裁**：多识别器并行（保准确率）vs 单 multilingual 模型（更简单）？
4. **模型打包**：内置 asset vs 首次启动下载（决策点 B）？
5. **翻译供应商**：默认锁定 GLM 流式，还是保留多供应商+流式开关（兼容弱网降级）？
6. 是否接受在 Phase A 先**只换 ASR、翻译暂保持非流式**，以隔离验证 ASR 收益？

> 请就上述决策点给出倾向，我将据此把本提案拆为 A/B/C 三阶段的具体改动清单，
> 并从 Phase A 开始，**每完成一阶段再次等待你确认**。
