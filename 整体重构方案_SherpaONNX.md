# 整体重构方案：Sherpa-ONNX 双语对话翻译器（v4.1）

> 版本：v4.1（2026-07-29，第五轮评审：非对称 TTS 策略显式化）
> 前置文档：`Project Review.md`（问题编号 S/M/L 沿用）、`架构升级提案_Sherpa-ONNX路径.md`
> 状态：**待用户确认，未修改任何代码**

---

## 〇之一、v4.1 相对 v4.0 的修订记录（第五轮评审）

| 评审点 | v4.0 表述 | v4.1 修订 |
|--------|-----------|-----------|
| TTS 朗读策略 | 「TtsQueue → flutter_tts，按 target 选 zh-CN/en-US/ru-RU」——读起来像"无差别朗读所有译文" | **非对称 TTS 升格为显式不变量（INV-TTS）**：`source=zh` → 朗读外语译文（面向对方）；`source=en/ru` → 仅中文大字幕，**静音**（面向自己，避免双声道干扰/回音）。过滤逻辑放在 LiveSession 分发处（TtsQueue 之前），en/ru 来源的译文流根本不进 TTS 队列 |

**事实核对**：现有代码 `live_session.dart _handleFinal()` 已经是这个行为（`lang=='zh'` 分支才 `tts.speak`，外语分支只出字幕）。v4.1 的意义是把这条从"代码里的隐式行为"升格为"重构不变量"，防止 Phase C 重写 TTS 链路时被无差别朗读退化掉。

---

## 〇、v4.0 相对 v3.1 的修订记录（第四轮评审）

| 评审点 | v3.1 设计 | v4.0 修订 |
|--------|-----------|-----------|
| 语言判定主判据 | 三层融合：logistic 标定分 0.6 + 字符特征 0.3 + 时间平滑 0.1 | **字符集判断为主判据**。zh（汉字）/ en（拉丁）/ ru（西里尔）字符集完全不重叠，final 文本一出即近乎确定性判定（>99%），不需要跨引擎置信度比较 |
| logistic 标定层 | 正式设计：每语言 100 句录音 + 拟合 (a,b) + tools/calibration/ | **整体删除**。标定基础设施的投入产出比对个人项目极差；raw confidence 仅在字符集模糊（极短词/数字/感叹词）时做粗略辅助排序，不标定 |
| 双识别器常驻竞争 | 双模型常驻、同帧双喂、每句竞争 | **删除**。改为**单识别器 sticky + 字符校验兜底**（方案B）：绝大多数时间只有一个识别器在跑，仅"疑似语言不符"时用另一识别器对同段 VAD 音频重解码一次 |
| bilingual-zh-en 模型 | Phase D 可选 A/B 实验 | **提前转正为 zh⇄en 模式唯一识别器**。单模型原生处理中英混说，该模式下语言判定问题整个消失；同时复用为 zh⇄ru 模式的 zh 侧 → 全 App 只需 2 个 ASR 模型 |
| 语言锁定状态机 | T_lock/T_switch/连续计数/窗口，输入为融合分 | **删除**。退化为简单 sticky：状态语言不变直到字符校验判定切换或用户手动点 Chip |
| 300 句测试集与硬验收 | >95% 准确率、误切换≤1、延迟<2s | **降级为"能用就行"**：自己拿真实对话跑几次，主观"好用、不烦人"即通过 |
| Phase 规划 | A(ASR) → B(标定+竞争) → C(GLM流式) → D(TTS) | **A(ASR+字符集方向判定) → B(GLM 流式翻译) → C(TTS 队列) → D(可选：zh⇄ru 自动切换打磨)**。自动语言切换从"必经阶段"降为"以后有空再玩" |

**历轮已定、v4.0 继续保留的原则**（评审确认为好设计，不再动）：
- partial → 仅 UI"正在听"预览；**final → 才进翻译**（防抖动、防 LLM 重复请求）。
- LLM token 永不直接进 TTS：GLM stream → SentenceSegmenter（。！？.!? 或 ≥20 字）→ TtsQueue。
- **INV-TTS 非对称朗读（v4.1 转正）**：只有 `source=zh` 的译文进 TTS；`source=en/ru` 只出中文字幕、永远静音。
- 同传专用约束 Prompt（不解释/不总结/不增内容/口语化/容忍 ASR 小错）。
- 模型全部打包 APK、全离线（目标设备不联网）；插件预编译 so 底座 + 自写调度层。
- Kotlin/Dart 职责边界：Kotlin 只管"听"（采集/VAD/推理），Dart 管 session/翻译/TTS/UI。
- 翻译多供应商（GLM/Qwen/Doubao）+ 流式开关，首包超时自动降级非流式。

---

## 一、产品定位与已确认决策

**定位：双语言实时对话翻译器（个人自用、免费、离线 ASR + 在线 LLM 翻译）**

| # | 决策 | 内容 |
|---|------|------|
| D1 | 两种模式 | `中文⇄英语`（默认）、`中文⇄俄语`。无第三种 |
| D2 | 全面转向 Sherpa-ONNX | 移除 Vosk / Google / flutter_sound；模型全部打包 APK |
| D3 | **语言判定极简化（v4.0）** | zh⇄en：bilingual 单模型，Dart 按字符集定翻译方向，无语言判定问题；zh⇄ru：单识别器 sticky + 字符校验兜底 + 手动 Chip 覆盖 |
| D4 | 插件底座 + 自写调度层 | 官方预编译 so + Kotlin API；自写采集/VAD/识别器管理 |
| D5 | 翻译多供应商 + 流式开关 | `stream:true` SSE 默认开，首包 3s 超时自动降级 |
| D6 | 分阶段落地 | Phase A/B/C 必做，D 可选；每阶段独立可运行、完成即停等确认 |

---

## 二、目标架构总览（v4.0）

```
┌──────────────────── Flutter (Dart：session/翻译/TTS/UI) ────────────────────┐
│                                                                            │
│  LivePage（Selector 局部刷新，Phase 1 成果保留）                              │
│      ▲                                                                     │
│  LiveSession（会话编排）                                                     │
│   ├── partial → 仅更新"正在识别"预览                                          │
│   ├── final {source, text} → TranslationRouter                             │
│   │        source 由字符集判定（CJK→zh / Latin→en / Cyrillic→ru）            │
│   │        模式表: zh⇄en 时 source=zh→target=en, source=en→target=zh        │
│   │        └→ TranslationService.translate(source, target, text)           │
│   │              ├ stream=true  → SSE delta → 字幕逐字浮现                   │
│   │              │       └→ [仅 source=zh] SentenceSegmenter → TtsQueue     │
│   │              └ stream=false → 整句返回（降级）→ [仅 source=zh] TtsQueue   │
│   ├── 非对称 TTS（INV-TTS）：source=zh → 朗读外语译文（手机替你说）             │
│   │                        source=en/ru → 仅中文大字幕，静音（你看字）        │
│   └── TtsQueue → flutter_tts，按 target 选 en-US / ru-RU（zh-CN 不会出现）   │
│      ▲                                                                     │
│      │ EventChannel 上行: {type: partial|final|vadStart|vadEnd|error,       │
│      │                    engine: "zhEn"|"ru", text}                       │
│      │ MethodChannel 下行: start(mode) / stop / setActiveLang(zh|ru|auto)   │
└──────┼──────────────────────────────────────────────────────────────────────┘
       │
┌──────┴───────────────── Android Kotlin（只做"听"）──────────────────────────┐
│  AudioSessionManager（生命周期/权限/幂等 start-stop/线程总控）                  │
│   ├── AudioCapture      AudioRecord → PCM16 mono 16kHz                     │
│   ├── VadProcessor      Silero VAD：说话开始/结束切句、静音不喂 ASR             │
│   │        └── SegmentBuffer：保留当前 VAD 段 PCM（供兜底重解码，仅模式 B）      │
│   ├── RecognizerManager 按模式加载识别器；任意时刻只喂一个（sticky）             │
│   │        模式 A（zh⇄en）：bilingual-zh-en ×1，无切换问题                    │
│   │        模式 B（zh⇄ru）：{bilingual, ru} 双加载单活跃 + 字符校验兜底重解码    │
│   └── SherpaRecognizer  单识别器包装：feed / partial / final / reset          │
└─────────────────────────────────────────────────────────────────────────────┘
```

与 v3.1 的最大结构变化：**Kotlin 层不再有 LanguageSelector 竞争模块**。语言相关逻辑只剩两处极简机制：
- Dart 侧 `TranslationRouter`：对 final 文本做字符集统计定 source（十几行代码，纯函数）。
- Kotlin 侧模式 B 的字符校验兜底（见第四节，机械规则，不含语义策略）。

---

## 三、模型选型与 APK 打包（v4.0 精简为 2 个 ASR 模型）

| 用途 | 模型 | 体积(int8) | 说明 |
|------|------|-----------|------|
| VAD | silero_vad.onnx | ~2MB | 两种模式共用 |
| 中文+英文 ASR | streaming-zipformer-**bilingual-zh-en**（官方，专为 code-switch 训练） | ~80MB | 模式 A 唯一识别器；模式 B 的 zh 侧复用 |
| 俄语 ASR | T-one russian streaming（CTC） | ~50MB | 模式 B 加载 |

- **v4.0 红利**：v3.1 需要 zh/en/ru 三个 mono 模型（~155MB），现在只需 2 个（~130MB），且 zh⇄en 混说（"我要 book 一个 hotel"）由模型原生解决。
- **打包**：全部放原生 `assets/`，Kotlin API 经 AssetManager 直读；`aaptOptions noCompress "onnx"`；`abiFilters arm64-v8a`。删除现有"首启解压 130MB zip"逻辑。APK 约 **150–170MB**。
- **内存**：模式 A 常驻 1 模型（~80MB 权重）；模式 B 双加载单活跃（~130MB 权重，但**推理只有一份**）。比 v3.1 双模型常驻双推理明显更省电省内存。
- **加载策略**：进入模式一次性加载该模式所需模型 → memory resident → 退出/切模式才释放。绝不逐句换载。

### 3.1 Phase A 首要验证点：bilingual-zh-en 模型质量
该模型是本方案的基石，Phase A 第一件事就是真机实测三种输入：纯中文、纯英文、中英混说。
- **达标**（主观：识别可用、不明显低于 Vosk）→ 按本方案继续。
- **不达标**（如纯英文识别明显差）→ 备选：模式 A 退回 zh + en 双 mono 模型 + 第四节的 sticky 兜底机制（与模式 B 同构，代码复用），不需要回到 v3.1 的标定竞争。

---

## 四、语言判定（v4.0 极简版）

### 4.1 核心洞察（评审第四轮）
中文（汉字/CJK）、英文（拉丁）、俄语（西里尔）**三者字符集完全不重叠**。识别器只要吐出几个字，字符集统计即可近乎确定性地判定语言（>99%），不需要置信度比较，更不需要跨引擎标定。v3.1 把最可靠的信号（字符集）当配菜、把最不可靠的信号（CTC vs Transducer 不可比分数）当主菜，属于本末倒置，v4.0 予以纠正。

### 4.2 模式 A（中⇄英）：无语言判定问题
- bilingual-zh-en 单模型自己输出中文或英文文字（含混说）。
- Dart `TranslationRouter` 对 final 文本统计 CJK/Latin 字符比例：CJK 占多 → source=zh, target=en；反之 source=en, target=zh。
- 混说句按主导字符集定方向（"我要 book 一个 hotel" → CJK 主导 → 译英）。
- **没有识别器切换、没有 sticky、没有兜底重解码**——这个模式下问题不存在。

### 4.3 模式 B（中⇄俄）：单识别器 sticky + 字符校验兜底（方案B）
```
进入模式：加载 bilingual(作 zh 用) + ru 两个识别器（双加载，单活跃）
state = 上次使用语言（默认 zh）

平时：只有 state 对应的识别器接收 PCM 帧（推理 ×1，省电省内存）
VadProcessor 同时把当前 VAD 段 PCM 存入 SegmentBuffer（最长 ~15s，环形）

每个 final：
  charMatch = final 文本字符集是否符合 state 语言
              （zh 状态期望 CJK 主导；ru 状态期望西里尔主导）
  if charMatch → 正常上抛 {source=state, text}，SegmentBuffer 清空
  else（疑似说话人换语言：zh 识别器对俄语音频通常输出乱码/空/极低分）：
      用另一识别器对 SegmentBuffer 里同段音频重解码一次
      比较两侧输出的字符集匹配度 → 胜者上抛，state 切换为胜者语言
      （极短词/数字等字符集模糊时，用 raw confidence 粗略排序辅助，不标定）
```
- **绝大多数时间单识别器运行**；只有语言切换边界那一句会触发一次额外解码（重解码一段 ≤15s 音频，int8 模型耗时几百 ms，可接受）。
- **手动 Chip 永远保留且优先**：UI 上"中文 / 俄语"标识当前录入语言，用户点按即强制 `state = X` 并清空兜底状态。发现判错随手一点即纠正——这是最终兜底，准确率 100%。
- 阈值只有一个："字符集主导"的判定比例（如 ≥60%），放 `AsrConfig`，凭经验设初值，不做正式标定。

### 4.4 明确删除的设计（v3.1 → v4.0）
| 删除项 | 原因 |
|--------|------|
| per-engine logistic 标定层 | 为"跨引擎分数不可比"造的解法；字符集判据下该难题被绕开而非解决——更好 |
| 每语言 100 句标定集 + tools/calibration/ | 采集+标注工作量超过写代码本身，个人项目投入产出比极差 |
| 三层融合公式（0.6/0.3/0.1） | 主判据换成字符集后无融合必要 |
| T_lock/T_switch 锁定状态机 | 退化为 sticky + 字符校验，两条 if 顶替一个状态机 |
| 双识别器常驻双喂帧 | 单活跃识别器 + 按需兜底重解码，省电省内存 |
| 300 句测试集 + >95% 硬指标 | 个人项目验收 = 真实对话跑几次，主观"好用、不烦人" |

---

## 五、Kotlin 层模块设计（asr/ 目录，5 文件）

| 文件 | 职责 |
|------|------|
| `AudioSessionManager.kt` | 生命周期总控：权限、幂等 start/stop、HandlerThread 管理、异常恢复 |
| `AudioCapture.kt` | AudioRecord，PCM16 mono 16kHz，帧输出 |
| `VadProcessor.kt` | Silero VAD：speechStart/speechEnd 切句、静音不喂 ASR；内含 SegmentBuffer（模式 B 兜底用，模式 A 不启用） |
| `RecognizerManager.kt` | 按模式加载/持有/释放识别器；sticky 单活跃喂帧；模式 B 的字符校验兜底重解码（机械规则：字符集统计 + 重解码 + 择优，不含语义策略） |
| `SherpaRecognizer.kt` | 单识别器包装：feed / partial / final / reset |

- v3.1 的 `LanguageSelector.kt`（标定/融合/状态机）**整体删除**。
- Channel 协议：
  - MethodChannel 下行：`start(mode: "zhEn"|"zhRu")`、`stop()`、`setActiveLang("zh"|"ru"|"auto")`（模式 B 手动 Chip / 自动）、`setConfig(json)`。
  - EventChannel 上行：`{type: partial|final|vadStart|vadEnd|error, text}`（source 判定在 Dart 字符集路由做，Kotlin 只报文本；模式 B 兜底切换时附 `langSwitched: "ru"` 提示字段）。

---

## 六、Dart 层改动清单

| 文件 | 动作 |
|------|------|
| `services/speech/vosk_engine.dart`、`google_engine.dart` | **删除** |
| `services/speech/speech_engine.dart` | 重写为 `NativeAsrEngine`：封装 Method/EventChannel，暴露 `start(mode)/stop/setActiveLang/partialStream/finalStream` |
| `services/live_session.dart` | 精简：删语种仲裁/粘滞窗口/字数缓冲；新增 `TranslationRouter`（字符集判 source + 模式表定 target，纯函数十几行）；模式字段 `zhEn|zhRu` |
| `services/translation_service.dart` | 接口改 `translate(source, target, text)`；新增 `translateStream(...)` SSE（Phase B）；Prompt 换同传约束模板（见 6.1） |
| `services/tts_service.dart` | Phase C：TtsQueue + SentenceSegmenter；按 target 选 en-US/ru-RU。**TtsQueue 自身不做语言过滤**——非对称过滤在 LiveSession 分发处（见 live_session 行），队列保持"给什么读什么"的单一职责 |
| `services/live_session.dart`（TTS 相关） | **INV-TTS 过滤点**：`source=zh` → 译文流接 SentenceSegmenter→TtsQueue；`source=en/ru` → 译文流只驱动字幕，不接 TTS。沿用现有 `_handleFinal` 的分支结构，重构时不得退化为无差别朗读 |
| `pages/live_page.dart` | 模式选择 UI（两枚模式卡片：中⇄英 / 中⇄俄）；"正在识别"预览区；模式 B 显示 zh/ru 手动 Chip；Selector 结构保留 |
| `pubspec.yaml` | 删 vosk_flutter/speech_to_text/flutter_sound；加 sherpa_onnx（仅取 so）；**解锁 Dart 3 / Flutter 3.22+**，http/flutter_tts/shared_preferences 升现代版本 |

### 6.1 同传 Prompt（保留）
```
你是实时口语翻译引擎。
任务：将输入内容直接翻译为目标语言（{target}）。
要求：
1. 保留原意
2. 使用自然口语
3. 不解释
4. 不总结
5. 不添加不存在的信息
6. 输入可能来自语音识别，允许少量错误，按最合理口语意图翻译
只输出译文本身。
```

---

## 七、Phase 规划（v4.0：A/B/C 必做，D 可选）

### Phase A：替换 ASR（不碰翻译）
- 工具链：pubspec 解锁 Dart 3、依赖升级、平台文件基线。
- **第一件事：真机验证 bilingual-zh-en 模型质量**（纯中/纯英/混说，见 3.1）；不达标走备选路径。
- Kotlin 层 5 文件落地；模式 A 用 bilingual 单识别器直接跑通（含 Dart 字符集方向判定）；模式 B 先手动 Chip 指定语言（sticky 自动切换留给 Phase D）。
- 模型打包 + AssetManager 加载；删除 Vosk/Google/flutter_sound 三条旧链路。
- **验收（能用就行）**：连续说话不卡、UI 不掉帧、识别观感不低于 Vosk、半小时长跑不崩。

### Phase B：GLM Streaming 翻译
- `translateStream(source, target, text)` SSE；流式开关 + 首包 3s 超时自动降级非流式。
- 删 `_runPunct` 独立标点请求（标点并入翻译 Prompt，S2/S6 消亡）。
- 只动 `TranslationService`，不碰 TTS。
- **验收**：final 出文到首个译文字明显变快（目标 <1s）；弱网降级不崩。

### Phase C：TTS 队列
- SentenceSegmenter + TtsQueue（非阻塞按序，S4 消亡）；按 target 选 TTS 语言。
- **INV-TTS 落地**：过滤在 LiveSession 分发处——只有 `source=zh` 的译文流接入 SentenceSegmenter→TtsQueue；`source=en/ru` 只驱动中文大字幕。这是现有代码已验证的行为，重写链路时必须保持。
- **验收**：长句边译边播不破碎、不互相打断；**对方说英/俄语时手机全程静音（只出字幕）**；你说中文时手机及时朗读外语。

### Phase D（可选，"以后有空再玩"）：模式 B 自动语言切换 + 打磨
- 4.3 的 sticky + 字符校验兜底重解码上线（在此之前模式 B 靠手动 Chip，已完全可用）。
- VAD 阈值、字符集主导比例等参数按实际使用手感微调。
- 低端机降配开关、死代码清理、CI 出包回归。

---

## 八、问题覆盖对照（对 Project Review.md）

| 问题 | 解决于 |
|------|--------|
| S1 非流式翻译 / S2 串行双 LLM / S6 _runPunct race | Phase B |
| S3 ASR 占 UI 线程 | Phase A（全部下沉 Kotlin 原生线程） |
| S4 TTS 阻塞 | Phase C |
| S5 / S7 / M1 / M2 / M6 / M7 / M10 | Phase 1 已修，全部保留 |
| M3 超时与连接复用 | Phase 1 已修；Phase B 扩展到 SSE |
| M4 / M5 语种仲裁散乱、缓冲逻辑复杂 | Phase A 消亡（模式 A 无仲裁）+ Phase D（模式 B 极简 sticky） |

---

## 九、历史版本要点存档（防止回退时丢上下文）

- **v3.1 的三层融合 + logistic 标定设计**：已删除。若未来模式 B 的字符校验兜底在真实使用中确实不够（预期不会——西里尔 vs 汉字判别近乎确定性），再考虑仅对"字符集模糊的极短词"做轻量置信度经验阈值，仍不做正式标定。
- **v3.0 的双识别器常驻竞争**：已删除，被"双加载单活跃 + 按需重解码"取代。
- **v2.0 的单一双语模型思路**：v4.0 实质回归并强化（bilingual 转正 + 复用到模式 B 的 zh 侧）。

---

**确认 v4.0 后，从 Phase A 第 1 步（pubspec 解锁 Dart 3 + 移除 Vosk 系依赖 + 工具链基线，并优先真机验证 bilingual-zh-en 模型质量）开始动码。**
