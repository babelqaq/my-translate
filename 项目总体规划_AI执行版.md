# 同声传译 APP 项目规划（AI 执行版）

> **本文档的读者是执行编码任务的 AI（如 Claude Code），不是人类。**
> 所有条款按"规则/约束/待执行步骤"而非"叙述说明"组织。禁止在未完成第 3 节资源验证前进入第 11 节的 Phase A 编码任务。文档内所有 `MUST` / `MUST NOT` / `禁止` / `必须` 均为强制约束，违反即视为实现错误，不是风格建议。本文档取代此前所有版本的项目规划文档，是唯一决策依据；不需要参考历史版本或历史讨论记录。

---

## 0. 项目一句话定义

个人自用 Android App。两种模式：
- 模式 A：中文 ⇄ 英语
- 模式 B：中文 ⇄ 俄语

听到外语（英/俄）→ 屏幕显示中文字幕。听到中文 → 用手机系统 TTS 朗读外语翻译。全程本地 ASR + 本地 VAD，仅翻译环节调用云端 LLM API。目标优先级（不可颠倒）：**准确 > 流式响应 > 实时性 > 实现简洁 > 界面美观**。

---

## 1. 产品决策（已锁定，MUST 遵守，不需要重新讨论是否合理）

| ID | 决策 | 说明 |
|----|------|------|
| D1 | 模式 A 使用 sherpa-onnx 官方 **bilingual zh-en 流式 zipformer 模型**作为唯一识别器 | 不做双识别器竞争，该模型原生处理中英混说 |
| D2 | 模式 B 使用两个独立流式识别器（zh + ru），**同一时刻只有一个在做推理**（sticky，按上一次判定结果决定当前用哪个） | 两个模型都常驻内存（约 130MB），但只有一个在跑推理，省 CPU/电量 |
| D3 | 语种判定 **只用字符集规则**（CJK / Latin / Cyrillic 字符占比），**不做任何跨引擎置信度融合、不做 logistic 回归标定** | 三种语言字符集互不重叠，字符集判定本身已接近确定性，标定的边际收益极低但工程成本很高，故禁止实现 |
| D4 | 用户可随时手动指定当前说话语种（UI 上的语种 Chip），手动值优先级高于任何自动判定 | 手动挡是保证准确率的最终兜底，MUST 优先于自动逻辑 |
| D5 | 翻译走云端 LLM 流式 API（GLM/Qwen/Doubao 三选一，可配置） | ASR/VAD/TTS 全部本地免费，只有这一环节联网 |
| D6 | TTS 使用 Flutter `flutter_tts`（系统自带引擎），不引入本地 TTS 模型 | 保持体积小、免费 |
| D7 | Phase A-C 阶段，模式 B 的"自动"档 **不实现任何自动切语言逻辑**，等价于强制手动 Chip；自动兜底重解码逻辑推迟到 Phase D 才实现 | 见 §11 Phase 划分，这是刻意的渐进交付顺序，不是遗漏 |

---

## 2. 强制不变量（INV-*，贯穿全部 Phase，任何实现都不可违反）

- **INV-NOCAL**：禁止实现任何形式的 ASR 置信度跨引擎标定/融合模型（如 logistic regression、softmax 校准）。语种判定只允许使用字符集规则 + sticky 状态 + 手动覆盖三者组合。
- **INV-MANUAL**：手动语种 Chip 的判定结果 MUST 无条件覆盖自动判定结果，且立即生效（不等待下一个 VAD 分段）。
- **INV-PARTIAL**：ASR partial 结果只能用于 UI 实时预览，MUST NOT 进入翻译流程；只有 final 结果才能触发翻译。
- **INV-TTS-BUFFER**：LLM 流式翻译输出 MUST NOT 逐 token 直接送入 TTS；MUST 经过句子级缓冲（SentenceSegmenter）按标点/子句边界切分后再送 TTS 播放队列。
- **INV-ROLE**：source=zh 时才触发"你在说话"分支（走翻译+TTS 朗读外语）；source∈{en, ru} 时走"对方在说话"分支（只出中文字幕，不触发 TTS）。这是设计假设，不是 bug：系统无法从声纹判断说话人身份，只能从识别出的语言映射说话角色。若用户主动说外语，会被系统当作"对方发言"处理，这是已知且接受的行为，不需要修复。
- **INV-OFFLINE-CORE**：ASR、VAD、TTS 三个环节 MUST 可在无网络环境下工作；只有翻译环节允许依赖网络。
- **INV-STICKY-SHORT**：语种判定对短文本（见 §8.2 `shortTextCharThreshold`）MUST 优先保持 sticky 状态，不允许仅凭一两个纯拉丁字母词（如 "OK" "Yes"）就把说话方向判定翻转。具体算法见 §8.2。

---

## 3. 外部资源清单与验证流程（阻塞性任务，MUST 在 Phase A-0 之前完成并把结果填回本节）

### 3.1 为什么这一节是阻塞性的

以下资源中有两类风险从文档层面无法消除，只能靠实际下载/加载来确认：
1. 模型来自非官方个人镜像仓库（ModelScope `zhaochaoqun/sherpa-onnx-asr-models`），随时可能缺文件或下线。
2. bilingual zh-en 模型发布于 2023-02-20，本项目使用的 sherpa-onnx AAR 是当前最新稳定版（写作时刻已知参考版本区间为 1.12.x～1.13.x，具体以下方验证结果为准），版本跨度大，MUST 实测确认新 AAR 能正常加载这个旧模型，而不是假设"官方保证向后兼容"就跳过验证。

**在完成下方"待验证资源表"全部打勾之前，MUST NOT 开始 Phase A 的任何编码任务。**

### 3.2 待验证资源表（执行时逐行填写"实际结果"列，不允许留空）

| 资源 | 来源 | 期望文件名/规格 | 验证动作 | 实际结果（执行时填写） |
|------|------|----------------|---------|----------------------|
| sherpa-onnx Android AAR | `https://github.com/k2-fsa/sherpa-onnx/releases` | 取 Releases 页面最新稳定版（非 rc/beta），文件名格式 `sherpa-onnx-<version>.aar`。写作时观察到的版本参考点：GitHub Releases 与 PyPI 显示的版本号可能不完全同步（如 Android AAR 常见于 1.12.x 系列，Python 包已到 1.13.x），**MUST 以实际打开 Releases 页面看到的最新非预发布版本为准，不要照抄本文档任何版本号** | 打开 Releases 页面，下载最新稳定版 AAR，记录真实文件名 | 版本号：**1.12.14**；文件名：**sherpa-onnx-1.12.14.aar**（已入库 `android/app/libs/`，AAR manifest minSdk=21 ≤ app 23，无冲突） |
| bilingual zh-en 流式模型 | sherpa-onnx 官方模型仓（HuggingFace / ModelScope 官方镜像，非个人仓） | `sherpa-onnx-streaming-zipformer-bilingual-zh-en-2023-02-20` | 1) 下载模型；2) 用上一行确认的 AAR 版本在真机/模拟器实际加载并跑一次识别，确认 `OnlineRecognizer` 初始化不报 config/tokens 格式错误 | 加载是否成功：**已接入**；asset 路径 `models/zh_en/`：`encoder-epoch-99-avg-1.int8.onnx` / `decoder-epoch-99-avg-1.int8.onnx` / `joiner-epoch-99-avg-1.int8.onnx` + `tokens.txt`（transducer，int8）。Kotlin `SherpaRecognizer` buildConfig 已按 v1.12.14 API 对齐 |
| silero VAD 模型 | ModelScope `zhaochaoqun/sherpa-onnx-asr-models`（个人镜像） | `silero_vad.onnx` | 实际访问该仓库页面，确认文件存在且可下载，记录文件体积 | 是否存在：**已入库**；asset 路径 `models/vad/silero_vad.onnx`，经 `SileroVadModelConfig` 加载，无报错 |
| 俄语 ASR 模型（T-one CTC） | 同上个人镜像仓 | `sherpa-onnx-streaming-*-ru-t-one-ctc-2025-*` 一类命名 | 同上，确认可下载 | 是否存在：**已入库**；asset 路径 `models/ru/model.onnx`（fp32，官方压缩包无 int8）+ `tokens.txt`，经 `OnlineZipformer2CtcModelConfig` 加载（模式 B 用） |
| 中文流式识别器（模式 B 用） | sherpa-onnx 官方模型仓 | 流式 zipformer 中文模型 | 确认可下载 | **模式 B 中文侧复用 bilingual zh-en 识别器**（见 `RecognizerManager`：模式 B 双加载 `{bilingual(作 zh), russian}`，activeLang=zh 时走 bilingual）。未单独引入中文 zipformer 模型——若后续要纯中文识别器再补 |

### 3.3 验证后必须同步的文档位置

一旦上表填完，MUST 把"实际文件名/版本号"回填到：
- §6 模型清单
- §10.2 gradle 依赖片段（AAR 文件名必须与实际下载文件**逐字符一致**，包括版本号，避免编译时 `File not found`）

**禁止在 §10.2 中硬编码一个未经 §3.2 验证的版本号。**

### 3.4 若 ModelScope 个人镜像资源缺失的回退顺序

1. 尝试 sherpa-onnx 官方 HuggingFace 仓库（`k2-fsa` 组织下对应模型）。
2. 尝试 sherpa-onnx GitHub Releases 中打包的示例 APK 附带模型（可从 APK 中提取 assets）。
3. 若两者都不可行，记录为阻塞项，暂停对应语言模式的开发，不要用未验证的替代模型硬凑。

---

## 4. 系统架构

```
                    ┌─────────────────────────────────────┐
                    │              Flutter (Dart)          │
                    │  UI / TranslationRouter / TTS队列    │
                    │  / SentenceSegmenter / LLM API调用   │
                    └───────────────▲───────────────────────┘
                                    │ MethodChannel / EventChannel
                    ┌───────────────┴───────────────────────┐
                    │              Kotlin (Android)          │
                    │  AudioCapture → VAD → RecognizerManager│
                    │  (bilingual模型 / zh+ru双模型sticky)   │
                    └─────────────────────────────────────────┘
```

数据流方向：
- **听觉输入**：麦克风 → Kotlin VAD 分段 → Kotlin ASR（partial/final）→ EventChannel 推给 Dart → Dart 语种路由 → 若 source=外语：仅推送字幕 UI；若 source=zh：推送 LLM 翻译 → SentenceSegmenter → TTS 队列 → 系统 TTS 播放。
- partial 结果只用于 UI 预览（INV-PARTIAL），不进入下游。

---

## 5. 模型清单

> 本节所有具体版本号/文件名以 §3.2 验证结果为准，此处只列出角色和体积量级，MUST NOT 在未验证前当作最终依据。

| 模型 | 用途 | 体积量级 | 使用模式 |
|------|------|---------|---------|
| bilingual zh-en 流式 zipformer | 模式 A 唯一识别器 | ~80MB | A |
| 中文流式 zipformer | 模式 B 中文侧识别器 | ~50MB | B |
| 俄语 T-one CTC 流式模型 | 模式 B 俄语侧识别器 | ~50MB | B |
| silero VAD | 语音分段（两种模式通用） | 数 MB | A/B |

模式 B 内存占用：中文模型 + 俄语模型均加载进内存（~130MB 常驻），但按 D2，同一时刻只有一个在做推理计算。

> **§3.2 验证后回填 — 实际 asset 文件名（位于 `android/app/src/main/assets/`）**：
> - bilingual zh-en：`models/zh_en/encoder-epoch-99-avg-1.int8.onnx` / `decoder-epoch-99-avg-1.int8.onnx` / `joiner-epoch-99-avg-1.int8.onnx` + `tokens.txt`（transducer int8，模式 A 唯一识别器；模式 B 作 zh 侧）
> - 俄语 T-one CTC：`models/ru/model.onnx`（fp32）+ `tokens.txt`
> - silero VAD：`models/vad/silero_vad.onnx`
> - 模式 B 中文侧：复用 bilingual 识别器，未单独引入中文 zipformer

---

## 6. 目录结构

```
lib/
  main.dart
  services/
    translation_router.dart      # 语种判定纯函数，见 §8.2
    translation_service.dart     # GLM/Qwen/Doubao 封装（原 llm_translate_service.dart，非流式）
    tts_service.dart             # flutter_tts 朗读封装（Phase C 将拆出 tts_queue.dart 句队）
    speech/native_asr_engine.dart # 与Kotlin层的Method/EventChannel封装（AsrEvent 内联于此）
    live_session.dart            # 会话编排：ASR事件→路由→翻译→分发
    app_settings.dart            # 配置持久化（mode/manualLang/streamEnabled 等）
  pages/
    live_page.dart               # 主界面（字幕+TTS+语种Chip）
    settings_page.dart           # 设置页（LLM供应商/Key/流式翻译开关）
  # sentence_segmenter.dart / tts_queue.dart：Phase C 实现（见 §11 Phase C）

android/app/src/main/kotlin/com/example/my_translate/asr/
  AudioCapture.kt                # 麦克风采集（原 AudioCaptureService.kt）
  VadProcessor.kt
  RecognizerManager.kt           # 模式A/B识别器加载与切换，见 §7
  SherpaRecognizer.kt            # 单识别器封装（transducer/CTC 统一接口）
  AudioSessionManager.kt         # 生命周期总控（权限/线程/启停幂等）
  AsrPlugin.kt                   # Channel 注册与事件发射（原 MainActivity 职责）
  AsrConfig.kt
  MainActivity.kt

android/app/libs/
  sherpa-onnx-1.12.14.aar        # 见 §3.2 验证结果

assets/models/
  zh_en/                         # streaming-zipformer-bilingual-zh-en（transducer）
  ru/                            # streaming-t-one-russian（CTC）
  silero_vad.onnx
```

---

## 7. Kotlin 层详细规格

### 7.1 `AudioCaptureService.kt`
- 职责：从麦克风采集 PCM 音频流，采样率 16kHz、单声道、16bit，MUST 与所选 ASR 模型的期望输入格式一致（若模型要求不同采样率，在此处重采样，不要交给 VAD 或识别器处理）。
- 输出：音频帧回调给 `VadProcessor`。

### 7.2 `VadProcessor.kt`
- 使用 silero VAD 做语音活动分段。
- 输出语音段边界（start/end 时间戳）给 `RecognizerManager`。
- 模式 B 需要维护一个环形缓冲区（≤15 秒，仅 Phase D 启用），供后续"重解码兜底"使用；Phase A-C 阶段这个缓冲区可以先实现但不必被调用。

### 7.3 `RecognizerManager.kt`（核心）

**模式 A：**
- 只加载 bilingual zh-en 一个 `OnlineRecognizer` 实例。
- 每个 VAD 语音段直接送入该识别器，partial/final 结果原样上抛给 Dart（语种判定完全交给 Dart 层的字符集规则，Kotlin 层不做任何语言判断）。

**模式 B：**
- 同时加载两个 `OnlineRecognizer`：zh 和 ru。
- 维护一个 `activeLang: Lang`（初始值 = 上次退出时保存的状态，或默认 zh）状态变量。
- 每个 VAD 语音段只送入 `activeLang` 对应的识别器做推理（另一个识别器不参与本段推理，只是模型权重留在内存里，随时可切换）。
- **Phase A-C**：`activeLang` 只能通过用户手动切 Chip（Dart 层下发 MethodChannel 指令）来改变。RecognizerManager 本身不做任何自动切换判断，也不做重解码。这是刻意的（见 D7），实现时不要"顺手"加自动逻辑。
- **Phase D**：新增"charMatch 兜底重解码"逻辑（详细算法见 §11 Phase D 任务描述），届时才会用到 §7.2 提到的环形缓冲区。

### 7.4 `MainActivity.kt`
- 注册 MethodChannel（Dart→Kotlin：切换模式、手动切语种、启停录音）与 EventChannel（Kotlin→Dart：partial/final ASR 事件、VAD 状态）。
- 事件协议见 §13.2。

---

## 8. Dart 层详细规格

### 8.1 模块职责

| 文件 | 职责 |
|------|------|
| `translation_router.dart` | 纯函数：输入 ASR final 文本 + 当前模式 + 手动语种 + sticky 语种，输出路由结果（源语言/目标语言/是否触发TTS）。**MUST 是纯函数，不依赖任何全局可变状态，必须可单测。** |
| `translation_service.dart` | 封装云端翻译 API 调用，`translate(source, target, text) -> String`（Phase A/B 非流式；Phase C 将新增 `translateStream` SSE，底层供应商可切换） |
| `tts_service.dart` | flutter_tts 朗读封装（Phase C 将拆出 `tts_queue.dart` 句队） |
| `sentence_segmenter.dart` | **Phase C 实现**：把 LLM 流式 token 缓冲成完整子句再交给 TTS（满足 INV-TTS-BUFFER） |
| `tts_queue.dart` | **Phase C 实现**：顺序播放句子，避免并发朗读打架 |
| `speech/native_asr_engine.dart` | 与 Kotlin 层的 Method/EventChannel 封装（AsrEvent 内联于此） |
| `live_session.dart` | 会话编排：ASR 事件 → 路由 → 翻译 → 分发（字幕/TTS） |

### 8.2 `translation_router.dart` —— `route()` 完整算法（MUST 严格按此实现，不要自行简化或增加融合逻辑）

```
输入:
  finalText: String
  mode: Mode (A | B)
  manualLang: Lang?        // 用户手动指定，null表示未手动指定，走自动
  stickyLang: Lang?        // 上一次判定出的source语种，null表示还没有历史

配置常量:
  charDominanceThreshold = 0.6       // 主导字符集占比阈值
  shortTextCharThreshold = 4         // 短文本字符数阈值（INV-STICKY-SHORT用）

算法:
1. 若 manualLang != null:
     return RouteResult(source = manualLang, target = mapTarget(manualLang, mode))
     # 手动挡直接返回，不进入任何自动判定逻辑（INV-MANUAL）

2. 统计 finalText 中三类字符数量（正则按Unicode区间匹配，忽略数字/标点/空白/emoji）：
     cjkCount      // \u4e00-\u9fff 等CJK统一表意文字区间
     latinCount    // 拉丁字母 a-zA-Z
     cyrillicCount // \u0400-\u04FF 西里尔字母区间
   totalRelevant = cjkCount + latinCount + cyrillicCount

3. 若 totalRelevant == 0:
     return null   # 完全无法判断（纯数字/纯标点），调用方按 stickyLang 处理，若stickyLang也为null则丢弃本段不路由

4. 找出三者中最大值对应的字符集 dominantScript，
   dominantRatio = max(cjkCount, latinCount, cyrillicCount) / totalRelevant

5. 若 dominantRatio < charDominanceThreshold:
     return null   # 混说但无主导语言，调用方按 stickyLang 处理

6. mappedLang = scriptToLang(dominantScript, mode)
   # cjk -> zh
   # latin -> en （仅mode A有效；mode B不应出现latin主导，若出现视为噪声，按第3步同样返回null处理，不强行映射）
   # cyrillic -> ru （仅mode B有效）

7. [INV-STICKY-SHORT 短文本保护] 若满足以下全部条件:
     - totalRelevant <= shortTextCharThreshold
     - stickyLang != null
     - mappedLang != stickyLang
   则:
     return null   # 证据不足以推翻sticky状态，调用方继续沿用stickyLang，不切换说话方向
   # 目的：防止"OK"/"Yes"/"是"这类极短纯外语惯用词被误判成说话人切换

8. 否则:
     return RouteResult(source = mappedLang, target = mapTarget(mappedLang, mode))
```

调用方（非本函数职责，由上层状态管理完成）逻辑：
```
result = route(finalText, mode, manualLang, stickyLang)
if result == null:
    effectiveLang = stickyLang ?? 默认语种(mode)   # 仍需要一个有效语种才能继续走翻译流程
else:
    effectiveLang = result.source
    stickyLang = result.source   # 更新sticky状态
按 effectiveLang 决定走 INV-ROLE 中的哪个分支
```

### 8.3 单元测试要求（MUST 编写，覆盖以下边界用例）

| 输入 | mode | stickyLang | 期望输出 |
|------|------|-----------|---------|
| "这个OK吗" | A | 任意 | source=zh（中文字符占主导） |
| "OK" | A | zh | route()返回null，effectiveLang沿用zh |
| "OK" | A | en | route()返回null（因为mappedLang==stickyLang其实相等，不触发短文本保护，直接进入第8步返回en）—— 注意此用例验证的是"mappedLang等于sticky时不应被短文本规则误拦截" |
| "Hello, how are you" | A | 任意 | source=en（词数够长，不触发短文本保护） |
| "123456" | 任意 | zh | route()返回null，effectiveLang沿用zh |
| "Привет" | B | zh | source=ru（西里尔字符主导，长度超过短文本阈值） |
| "" | 任意 | 任意 | route()返回null |

---

## 9. 关键数据流时序（举例，实现时以此为验收参照）

**场景1：模式A，对方说英文**
```
麦克风 -> VAD分段 -> bilingual识别器 -> final="How are you"
-> Dart route(): cjk=0, latin主导, ratio=1.0 >= 0.6, 长度>4 -> source=en
-> INV-ROLE: source≠zh -> 只推送中文字幕（需先调用LLM做 en->zh 翻译得到字幕文本），不触发TTS
```

**场景2：模式A，你说中文**
```
final="今天天气怎么样"
-> route(): source=zh
-> INV-ROLE: source=zh -> 调用LLM流式翻译 zh->en -> SentenceSegmenter按子句切 -> TTS队列依次朗读
```

**场景3：模式A，你随口回一个"OK"，stickyLang=zh**
```
final="OK"
-> route(): totalRelevant=2 <= shortTextCharThreshold(4)，mappedLang=en != stickyLang=zh -> 返回null
-> 调用方沿用 stickyLang=zh -> 走"你在说话"分支，尝试翻译"OK"并朗读（合理，因为这确实是你说的话）
```

---

## 10. 构建与 CI

### 10.1 Gradle 依赖（占位符 MUST 在 §3.2 验证完成后替换为实际值，禁止提前填入未验证的版本号）

```gradle
dependencies {
    implementation files('libs/sherpa-onnx-1.12.14.aar')   // §3.2 验证结果：actual filename，与 android/app/libs/ 内逐字符一致
}
```

### 10.2 minSdkVersion
- 当前配置：23。实现时在 §3.2 真机验证阶段一并确认该 AAR 版本对 minSdk 的实际要求，若 AAR 要求更高版本，MUST 同步上调并记录在此处，不要事后才发现编译报错。

### 10.3 CI
- 模型资源体积较大，CI 流程中的模型下载步骤 MUST 指向 §3.2 验证后确认可用的实际地址（GitHub Actions/Codemagic 均可），不要在 CI 脚本里硬编码个人镜像仓的猜测路径。

---

## 11. 分阶段任务清单与验收标准

### Phase A-(-1)：资源验证（阻塞性，先于一切编码）
- 任务：完成 §3.2 全部表格填写。
- 验收：表格所有行"实际结果"列非空，且所有"是否存在/是否成功"均为是；若有"否"，必须先走 §3.4 回退流程直到全部为"是"才能进入下一阶段。

### Phase A-0：真机可行性验证
- 任务：用 §3.2 确认的 bilingual 模型 + AAR，在真机上跑通一次完整的流式识别（不需要完整UI，命令行/最小demo即可）。
- 验收：
  1. 模型加载无异常（config/tokens格式兼容，见 §3.2 第2行）。
  2. 对一段中英混说的真实语音，能拿到合理的 final 文本（不要求100%准确，只要求流程能跑通、文本基本可读）。

### Phase A：模式A最小可用版本
- 任务：实现 §4-§9 中模式A相关的全部模块（AudioCapture、VAD、bilingual识别器接入、route()、SentenceSegmenter、TTS队列、LLM翻译调用、基础UI）。
- 验收：
  1. 对着手机说中文，能听到英文TTS朗读。
  2. 播放一段英文语音，屏幕能显示中文字幕。
  3. `translation_router.dart` 的 §8.3 单元测试全部通过。
  4. 手动语种Chip优先级验证：即使字符集判定结果与手动指定不同，MUST以手动为准。

### Phase B：模式B最小可用版本
- 任务：实现模式B的双识别器加载 + sticky切换（D2/D7）。
- 验收：
  1. 手动切换Chip在zh/ru之间，识别器能正确切换到对应模型推理。
  2. **明确验收点（避免误判为缺陷）**：本阶段"自动"档不做任何自动切换，UI上选中"自动"后系统行为等价于停留在当前sticky语种直到用户手动切换；这是预期行为。

### Phase C：稳定性与体验打磨
- 任务：
  1. **启用流式翻译**：实现 `sentence_segmenter.dart`（LLM 流式 token → 子句缓冲，满足 INV-TTS-BUFFER）+ `tts_queue.dart`（顺序播放队列），新增 `translateStream` SSE 接口并打开 `streamEnabled`。
  2. 异常处理（识别器加载失败降级、网络失败重试、TTS队列打断逻辑）、UI细节。
- 验收：连续使用（如30分钟真实对话场景）不崩溃、不内存泄漏、TTS不重叠播放；流式翻译逐字浮现且不逐 token 直送 TTS。

### Phase D：模式B自动兜底（可选，非MVP必需）
- 任务：实现 §7.3 提到的"charMatch兜底重解码"——当 activeLang 对应识别器输出的文本字符集与 activeLang 本身不匹配时（例如zh识别器在ru语音上输出的乱码/低置信度文本无法构成合理CJK主导），用 §7.2 环形缓冲区对同一段音频用另一个识别器重新推理一次，两次结果按字符集匹配度择优，胜出者成为新的 activeLang。
- 验收：模式B在不点Chip的情况下，双方交替用中/俄对话时，系统能在合理延迟内（目标<2秒）自动切换识别方向，且不显著增加平均功耗（对比Phase A-C功耗基线）。

---

## 12. 风险与回退

| 风险 | 影响 | 缓解/回退 |
|------|------|-----------|
| ModelScope个人镜像仓失效或文件缺失 | 阻塞俄语模式开发 | 按§3.4顺序回退到官方HuggingFace/APK提取 |
| bilingual模型与新版AAR不兼容 | 阻塞模式A开发 | Phase A-0阶段优先暴露该问题；若不兼容，改用更接近模型发布年份的历史AAR版本，或寻找官方是否发布过更新的bilingual模型版本 |
| 短文本误判说话方向（INV-STICKY-SHORT覆盖不全的边界case） | 体验问题，不影响核心可用性 | 已在§8.2算法中处理主要case；若上线后发现新的误判模式，调整`shortTextCharThreshold`数值即可，不需要改算法结构 |
| 模式B双模型常驻内存占用（~130MB） | 低端设备可能内存紧张 | 个人自用场景可接受，暂不做懒加载优化；若后续需要，可在切换到某语种时才加载对应模型、退出时释放另一个，作为Phase D之后的可选优化项 |
| LLM流式API返回不稳定/超时 | 翻译中断 | `llm_translate_service.dart` MUST实现超时重试（1次）+ 用户可见的失败提示，不要静默失败 |

---

## 13. 附录

### 13.1 LLM翻译Prompt模板（同传专用，MUST遵守约束）
- 约束：不解释、不总结、不添加原文中没有的内容；对ASR识别错误保持一定容忍度，不要因为个别字词识别错误就拒绝翻译或大幅改写句意；输出流式、逐句可分割。
- ASR识别错误应按语义意图纠正：输入为语音识别结果，可能含同音词混淆（如 sun/sound）、口误重复等；翻译前应结合上下文推断说话人真实意图，对明显的识别错误不要逐字直译，但不得借机臆造原文没有的内容。
- 具体prompt文本由`translation_service.dart`实现时维护，此处不重复展开，避免和实现产生不一致；以代码中的常量为准。

### 13.2 Kotlin↔Dart 事件协议

> 注：以下为 Phase A/B 实际实现（以代码为准）。`lang`(partial)/`timestamp`(final)/`vad_status` 为 **Phase D 预留字段**，当前未携带；`route()` 只吃 `finalText`，语种判定权威地由 Dart 层重新计算。

**EventChannel（Kotlin→Dart）事件类型（JSON 字符串）：**
```
{ type: "ready" }
{ type: "status", text: String }
{ type: "partial", text: String }                 // lang 字段 Phase D 预留，当前不携带
{ type: "final", text: String }                   // timestamp 字段 Phase D 预留，当前不携带
{ type: "error", text: String }
```

**MethodChannel（Dart→Kotlin）指令：**
```
start(mode: "zhEn"|"zhRu")
stop()
setActiveLang(lang: "zh"|"ru"|"en"|"auto")        // 模式B手动Chip；模式A单识别器忽略
setConfig(config: JSON字符串)                      // AsrConfig 热更新
```

### 13.3 配置参数汇总

| 参数 | 位置 | 默认值 | 说明 |
|------|------|--------|------|
| `charDominanceThreshold` | `translation_router.dart` | 0.6 | 字符集主导判定阈值 |
| `shortTextCharThreshold` | `translation_router.dart` | 4 | 短文本sticky保护阈值 |
| VAD分段静音阈值 | `VadProcessor.kt` | 沿用silero VAD默认推荐值 | 实现时如需调整需记录理由 |
| TTS语速/音色 | `tts_queue.dart` | 系统默认 | 可后续加UI设置项，非MVP必需 |

---

**文档结束。执行顺序：先完成 §3 阻塞性验证并回填结果，再按 §11 Phase顺序推进，不可跳过Phase A-(-1)和A-0直接开始写业务代码。**
