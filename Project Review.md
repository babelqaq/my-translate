# Project Review — my_translate 实时同声传译 APP

> 评审范围：`lib/` 全部 11 个 Dart 文件、`pubspec.yaml`、`codemagic.yaml`、`.github/workflows/build-apk.yml`、`BUILD.md`、`OVERVIEW.md`、`tools/download_models.sh`
> 评审目标：以「接近 ChatGPT Voice 的实时翻译体验」为唯一标尺，按 ① 翻译准确率 ② 流式体验 ③ 实时响应 ④ 代码简洁性 逐项诊断。
> 本文件只做诊断与方案，**不改动任何源码**，待你确认后再进入第二阶段。

---

## 一、当前项目架构

### 1.1 模块清单与职责

| 文件 | 行数 | 职责 | 评价 |
|---|---|---|---|
| `lib/main.dart` | 27 | 入口；手动构造依赖链（settings→translation→tts→session）并 runApp | 简洁，OK |
| `lib/app.dart` | 54 | MaterialApp + MultiProvider 注册 4 个 provider | OK |
| `lib/services/app_settings.dart` | 128 | 设置持久化（ChangeNotifier + shared_preferences）；LLM 预设表 | 清晰，OK |
| `lib/services/translation_service.dart` | 170 | LLM 翻译 + 标点恢复（OpenAI 兼容，**非流式**） | 实时性短板集中地 |
| `lib/services/tts_service.dart` | 67 | flutter_tts 同传朗读（ChangeNotifier） | 基本可用 |
| `lib/services/speech/speech_engine.dart` | 24 | 引擎抽象接口 | OK |
| `lib/services/speech/vosk_engine.dart` | 350 | Vosk 双模型离线引擎：录音→双识别器→置信度语种仲裁→黏滞→手动提示 | 功能完整，但跑在 UI 线程 |
| `lib/services/speech/google_engine.dart` | 70 | speech_to_text 在线引擎（单语种） | OK |
| `lib/services/live_session.dart` | 365 | **核心编排器**：监听→判别→流式分段→翻译→路由字幕/同传；ChangeNotifier 状态源 | 职责过重，是最大优化点 |
| `lib/pages/live_page.dart` | 250 | 主界面：状态条+partial 预览+大字幕 ListView+手动语种+开始/停止 | rebuild 过宽 |
| `lib/pages/settings_page.dart` | 171 | 设置页 | OK |

### 1.2 调用关系

```
main.dart
  └─ AppSettings.load()
  └─ 构造 TranslationService / TtsService / LiveSession
  └─ runApp(MyTranslateApp)

app.dart (MultiProvider)
  ├─ ChangeNotifierProvider<AppSettings>
  ├─ Provider<TranslationService>
  ├─ ChangeNotifierProvider<TtsService>
  └─ ChangeNotifierProvider<LiveSession>
       │
       ├─ start() → VoskEngine/GoogleEngine.initialize + start
       │            │
       │            └─ flutter_sound 录音 Stream → VoskEngine._onAudio
       │                  ├─ 双识别器 acceptWaveformBytes（4096B 切片）
       │                  ├─ _arbitrate（置信度 + 黏滞 + 手动提示）
       │                  └─ onSegment(text, isFinal, lang) ──┐
       │                                                     │
       └─ _onSegment ◄────────────────────────────────────────┘
            ├─ partial: 覆盖 _streamBuffer + notifyListeners
            │           + _armPunctTimer(400ms 防抖 / 1500ms 周期)
            │           + _armSilenceTimer(1200ms 兜底)
            │     └─ _runPunct → translation.punctuate（LLM #1 非流式）
            │           └─ 按最后一个句末标点切句 → _handleFinal
            │
            └─ final: 合并缓冲 → _flushStream → _handleFinal
                  └─ _handleFinal → translation.translate（LLM #2 非流式）
                        ├─ 中文源: await tts.speak（阻塞至朗读完）
                        └─ 外语源: _notes.add + notifyListeners

LivePage: context.watch<LiveSession>() → 整页 rebuild
```

### 1.3 线程模型

- **全部运行在 Flutter UI isolate 的 event loop 上**（Dart 单线程）。
- `VoskEngine._onAudio` 在 UI 线程执行：每来一个音频 chunk，循环按 4096 字节切片，**串行 await** 两个识别器的 `acceptWaveformBytes` / `getResult` / `getPartialResult`（native FFI/JNI 调用）。
- LLM 翻译/标点用 `http.post`（非流式），await 期间 UI 不卡但延迟高。
- **没有任何 Isolate** 承担 ASR 或翻译计算。

### 1.4 状态管理

- Provider + ChangeNotifier。
- `LiveSession` 是唯一的状态源：`notes / status / statusText / partial / partialLang / message / manualLang`。
- 每次 partial 更新都 `notifyListeners()`，`LivePage` 用 `context.watch` 整页 rebuild。

### 1.5 优点

1. **分层清晰**：services / pages / speech 三层职责边界明确，新人 10 分钟能看懂。
2. **双模型语种仲裁设计扎实**：置信度比较 + 黏滞窗口 + 手动提示三级策略，是离线自动判别的合理实现。
3. **流式分段有思考**：partial 覆盖式更新 + 标点防抖 + 静默兜底 + 词数硬上限，四道兜底确保不丢句。
4. **资源释放基本到位**：`stop()` / `dispose()` 都 cancel 计时器、关 recorder、stop tts。
5. **容错兜底多**：标点失败退化、翻译失败提示、幻觉检测、无意义语气词过滤。
6. **依赖链手动注入**：main 里显式构造，便于测试与替换。

### 1.6 缺点

1. **实时性实现与目标严重不符**：翻译走非流式 HTTP，每句等完整 RTT+生成才显示，与 ChatGPT Voice 的"边生成边显示"差距巨大。
2. **每句串行两次 LLM**（标点 + 翻译），延迟翻倍。
3. **ASR 跑在 UI 线程**，音频高频回调持续抢占 UI，潜在 jank。
4. **`LiveSession` 职责过重**：365 行塞了状态管理 + 流式分段 + 语种路由 + 翻译调度 + TTS 调度 + 上下文窗口 + 语气词过滤，违背"单一职责"。
5. **TTS 同传阻塞翻译循环**：`await tts.speak` 等整句朗读完，连续中文会堆积。
6. **构建配置不一致**：codemagic.yaml 的 Flutter 3.44.5 与 pubspec 的 Dart 2.x 直接冲突，Codemagic 路径不可用。

### 1.7 架构评分（10 分制）

| 维度 | 分数 | 说明 |
|---|---|---|
| 模块划分 | 7.0 | services/pages 分层清晰；speech 子包合理 |
| 状态管理 | 5.5 | Provider 够用，但 LiveSession 过重，状态字段散乱 |
| **实时性** | **3.0** | 非流式翻译 + 串行双 LLM + UI 线程 ASR，与目标差距最大 |
| **流式处理** | **4.0** | partial 限流与标点防抖有想法，但标点+翻译串行打折 |
| 线程模型 | 3.0 | 全在 UI 线程，无 Isolate |
| 资源释放 | 7.0 | 计时器/recorder/tts 都有释放 |
| 异常处理 | 5.0 | try-catch 兜底多，但无超时/重试/降级 |
| 代码简洁 | 6.0 | 整体简洁，LiveSession 过长；少量死代码 |
| 测试覆盖 | 1.0 | 无任何测试 |
| 构建配置 | 5.0 | GH Actions 正确，Codemagic 版本冲突 |
| **综合** | **5.0** | 架构清晰但实时性实现是核心短板 |

---

## 二、发现的问题

### 2.1 严重（直接影响 ①②③ 目标）

#### S1. 翻译走非流式 HTTP（`stream: false`）—— 流式体验与实时响应的最大短板
- 位置：`translation_service.dart:94` `translate()`、`:151` `punctuate()`
- 现象：每次 `_handleFinal` 都 `await http.post` 等整个响应体返回，UI 在此期间无任何渐进反馈。用户说完一句到看到译文，延迟 = 网络 RTT + 模型首 token + 完整生成 + 解析。
- 影响：**与 ChatGPT Voice 体验直接冲突**。ChatGPT Voice 的关键是 SSE 流式输出，译文逐 token 浮现，体感延迟≈首 token 时间。当前实现体感延迟≈完整生成时间。
- 与原则冲突：违反 ② 流式体验、③ 实时响应。

#### S2. 每句串行两次 LLM（标点 + 翻译）—— 延迟翻倍
- 位置：`live_session.dart:209` `_runPunct()` → `translation.punctuate`，`:278` `_handleFinal()` → `translation.translate`
- 现象：partial 防抖 400ms → 标点请求（等 RTT+生成）→ 切句 → 翻译请求（再等 RTT+生成）。最坏路径（标点失败退静默兜底）：400ms + 标点RTT + 1200ms + 翻译RTT。
- 影响：每句话要付两次 LLM 串行延迟。标点请求本身不产出译文，纯开销。
- 与原则冲突：违反 ③ 实时响应。

#### S3. ASR 识别在 UI 线程 —— 潜在卡顿
- 位置：`vosk_engine.dart:176` `_onAudio()`、`:183` 4096 字节循环
- 现象：`flutter_sound` 的 stream 监听回调在 UI 线程执行。`_onAudio` 内对每个 chunk 循环切片，每片 `await _foreign!.acceptWaveformBytes(sub)` + `await _zh!.acceptWaveformBytes(sub)`，这些是 native FFI 调用，会在 platform channel 上同步执行，抢占 UI 线程的微任务调度。音频 chunk 高频到达（16kHz/16bit ≈ 32KB/s，每秒约 8 个 4096B 切片 ×2 识别器 = 16 次 native await）。
- 影响：持续录音期间 UI 线程被高频占用，ListView 滚动、按钮响应、partial 文本刷新都可能掉帧。
- 与原则冲突：违反 ③ 实时响应。

#### S4. TTS 同传阻塞翻译循环 —— 连续中文堆积
- 位置：`live_session.dart:289` `await tts.speak(foreign, language: ttsLang)`；`tts_service.dart:32` `await _tts.awaitSpeakCompletion(true)`
- 现象：`awaitSpeakCompletion(true)` 使 `speak` 直到整句朗读完才返回。`_handleFinal` 里 `await tts.speak`，意味着第二句中文的翻译要等第一句外语朗读完才开始。
- 影响：连续说中文时，翻译请求排队，越堆越多，同传"声传"变成"读一句停一句"。同声传译应是边说边译边读，朗读不应阻塞下一句的识别与翻译。
- 与原则冲突：违反 ②③。

#### S5. codemagic.yaml Flutter 版本与 pubspec 冲突 —— Codemagic 构建路径不可用
- 位置：`codemagic.yaml:6` `flutter: "3.44.5"` vs `pubspec.yaml:9` `sdk: '>=2.17.0 <3.0.0'`
- 现象：3.44.5 是 Dart 3.x，pubspec 锁 Dart 2.x，`flutter pub get` 会直接报 `version solving failed`。GitHub Actions 正确锁了 3.7.12。
- 影响：BUILD.md 推荐的"方案 B：CodeMagic"完全跑不通，用户按文档操作会失败。
- 违反：代码一致性。

#### S6. `_runPunct` 与 partial 覆盖式更新存在 race —— 流式内容可能丢失
- 位置：`live_session.dart:178` `_streamBuffer = text.trim()`（partial 覆盖）vs `:220` `_streamBuffer = rest`（标点返回后写回半句）
- 现象：`_runPunct` 是 async，发起请求时快照读 `_streamBuffer`。请求在途期间，新 partial 到达会把 `_streamBuffer` 覆盖成新全量。`_runPunct` 返回后执行 `_streamBuffer = rest`（句号后的半句），**覆盖掉期间 partial 写入的新内容**。
- 影响：用户持续说话时，标点请求往返期间新说出的内容可能被丢弃，导致译文漏字。
- 违反：① 翻译准确率（漏内容）、② 流式体验。

#### S7. `stop()` 顺序混乱 —— 停止时仍在触发翻译与 TTS
- 位置：`live_session.dart:318` `stop()`
- 现象：顺序为 `_engine.stop()` → `tts.stop()` → 清空计时器 → `_flushStream()`（会触发 `_handleFinal` → 翻译 → `tts.speak`）→ `_setStatus('idle')`。即先停了 tts，又在 flushStream 里重新 speak，且此时状态已切 idle 但翻译在后台跑。
- 影响：停止后可能出现"已停止"却突然朗读一句的怪异行为；后台翻译若失败也无 UI 反馈。
- 违反：稳定性、用户体验。

### 2.2 中等

#### M1. `LivePage` 整页 `watch`，partial 每 140ms 触发整页 rebuild
- 位置：`live_page.dart:35` `context.watch<LiveSession>()`
- 现象：Vosk 限流 140ms 发一次 partial，每次 `notifyListeners` 触发整页 rebuild（状态条 + partial 预览 + ListView + ChoiceChip + 按钮）。
- 影响：录音期间持续高频 rebuild，ListView 若条目多会卡顿。
- 违反：③ 实时响应（UI 流畅度）。

#### M2. `addPostFrameCallback` 写在 `build` 里 —— 回调堆积
- 位置：`live_page.dart:41`
- 现象：每次 rebuild 都注册一个 postFrame 回调，partial 高频刷新时每帧都注册，虽不会内存泄漏（一次性回调）但逻辑不清晰，且无字幕时也触发滚动。
- 影响：轻微性能浪费，代码意图不清。

#### M3. LLM 请求无超时、无连接复用 —— 慢网络下 UI 无限等待
- 位置：`translation_service.dart:80` `http.post`
- 现象：每次 `http.post` 都是默认 `http.Client`（无 keep-alive 池），无 `timeout`。网络慢时 `_handleFinal` 一直 await，UI 无降级。
- 影响：弱网下体验断崖。
- 违反：③。

#### M4. `_onAudio` 串行喂两个识别器 —— 可并行
- 位置：`vosk_engine.dart:188-189`
- 现象：`foreignReady = await _foreign!.acceptWaveformBytes(sub);` 然后 `zhReady = await _zh!.acceptWaveformBytes(sub);` 串行。
- 影响：每片多一倍 native 往返。可 `Future.wait` 并行（native 侧是否真并行取决于插件实现，但至少 Dart 侧不串行）。

#### M5. `_recentSources` 上下文窗口无并发保护 —— 顺序错乱
- 位置：`live_session.dart:314`
- 现象：`_handleFinal` 是 async，多个 `_handleFinal` 可并发（partial 触发的 `_runPunct` 与 final 触发的 `_flushStream` 可能交叉）。翻译完成顺序与发起顺序不一致，`_recentSources.add(text)` 按完成顺序写入，上下文窗口可能错乱。
- 影响：上下文消歧质量下降，轻微影响准确率。
- 违反：①。

#### M6. 状态字符串硬编码 —— 易错
- 位置：`live_session.dart:38` `'idle' | 'loading' | 'listening' | 'error'`，`live_page.dart:38,86` 字符串比较
- 现象：用 String 表示状态，拼写错无编译期保障。
- 影响：维护成本。

#### M7. 手动语种 ChoiceChip 写死"英文" —— 俄语模式下错误
- 位置：`live_page.dart:206` `session.setManualLang('en')` + `label: const Text('英文')`
- 现象：当 `settings.foreignLang == 'ru'` 时，第三个 chip 仍显示"英文"且 `setManualLang('en')`，但 VoskEngine 此时的外语是 ru，`_arbitrate` 里 `preferred == _foreignLang`（即 'ru'）才匹配外语分支，传 'en' 会被当成无效提示。
- 影响：俄语用户用手动语种功能完全失效。
- 违反：①（语种判别错误）。

#### M8. Google 引擎切外语后不重置 —— `_ready` 残留
- 位置：`google_engine.dart:48` `if (!_ready) await initialize(...)`
- 现象：切换外语后 `_ready` 仍为 true，不会重新 initialize，`_foreignLang` 在 start 时才用。实际 `start` 里用 `localeId ?? (_foreignLang == 'ru' ? 'ru-RU' : 'en-US')`，但 `_foreignLang` 是 initialize 时设的旧值。
- 影响：设置页切外语后需手动停止重启才生效，体验差。

#### M9. `TtsService.speaking` 状态未被 UI 使用 —— 多余通知
- 位置：`tts_service.dart` 全部 `notifyListeners()`
- 现象：`LivePage` 从未读 `tts.speaking`，但每次 start/completion/error 都 `notifyListeners`，触发 `LiveSession` 同帧额外的 provider 重建。
- 影响：轻微性能浪费。

#### M10. `_kMaxWords` 按空格分词 —— 对中文永远 1
- 位置：`live_session.dart:184` `_streamBuffer.split(RegExp(r'\s+')).length >= _kMaxWords`
- 现象：中文无空格，整段中文缓冲 split 后长度恒为 1，永不触发主动提交。中文完全依赖静默兜底（1200ms）。
- 影响：中文长独白会等满 1200ms 才提交，体感延迟高。
- 违反：③。

### 2.3 轻微

#### L1. `translate` 与 `punctuate` 的 http.post 样板重复
- 位置：`translation_service.dart:80-96` 与 `:137-153`
- headers / body / 状态码检查 / choices 解析几乎一致，应抽 `_chat(system, user, temperature)`。

#### L2. `_kRepoSlug` 硬编码 GitHub 仓库
- 位置：`vosk_engine.dart:16` `const String _kRepoSlug = 'babelqaq/my-translate';`
- 换仓库要改代码，应走设置或环境变量。

#### L3. ghproxy 镜像列表硬编码且部分已失效
- 位置：`vosk_engine.dart:96-101`
- `ghproxy.com` 等镜像不稳定，应可配置或动态探测。

#### L4. `TtsService.setVolume` 从未被调用 —— 死代码
- 位置：`tts_service.dart:58`

#### L5. `SpeechEngine.start` 的 `localeId` 参数从未传入 —— 接口冗余
- 位置：`speech_engine.dart:20`，调用处 `live_session.dart:145` 未传

#### L6. `app.dart` 注册了 `/settings` 路由，但实际用 `MaterialPageRoute` 跳转 —— 死路由
- 位置：`app.dart:49` vs `live_page.dart:61`

#### L7. `NoteEntry.time` 从未在 UI 显示 —— 冗余字段
- 位置：`live_session.dart:15`

#### L8. `VoskEngine` 用 `print` 而非 `debugPrint` —— release 包也会输出
- 位置：`vosk_engine.dart:126-127`

#### L9. `assets/.gitkeep` 与实际模型并存 —— 多余
- 模型已实际存在，`.gitkeep` 失去意义。

#### L10. 无任何测试
- `pubspec.yaml` 仅 `flutter_lints`，无 test 目录，无单元/集成测试。

#### L11. `codemagic.yaml` 的 `sed -i ''` 是 BSD 语法
- `instance_type: mac_mini_m1` 下正确，但与 GH Actions 的 GNU `sed -i` 不一致，维护成本。

#### L12. `_isMeaningless` 的 `_fillers` replaceAll 顺序敏感
- 位置：`live_session.dart:101-104`
- "就是" 会匹配 "就是说" 的前缀，小概率误伤。影响极小。

---

## 三、建议优化方案

> 每项标注：为什么改 / 收益 / 风险 / 影响文件 / 是否推荐。
> 「推荐」标准：对 ①②③ 有正向收益且风险可控。优先级严格遵循 ①>②>③>④。

### 3.1【强烈推荐·P0】翻译改 SSE 流式输出（直击 S1）
- **为什么**：当前非流式是实时性最大短板。SSE 流式让译文逐 token 到达，UI 边收边显示，体感延迟从"完整生成时间"降到"首 token 时间"，这是 ChatGPT Voice 体验的核心。
- **收益**：② 流式体验质变；③ 体感延迟降低 50%+；不降低 ①（同样模型同样 prompt，准确率不变）。
- **风险**：中。需处理 SSE 解析、UI 逐字渲染、中断/取消、超时。国内 LLM 的 OpenAI 兼容接口均支持 `stream: true`，已验证。
- **影响文件**：`translation_service.dart`（重写 translate 为 Stream<String>）、`live_session.dart`（_handleFinal 改为消费 Stream 并增量更新 NoteEntry）、`live_page.dart`（字幕增量刷新）。
- **是否推荐**：✅ 是，P0。

### 3.2【强烈推荐·P0】标点 + 翻译合并为一次流式 LLM（直击 S2）
- **为什么**：标点请求纯开销，且与翻译串行。合并为"输入 ASR 原文 → 模型直接输出带标点译文"一次调用，省一次 RTT，且流式输出。
- **收益**：③ 延迟减半；② 译文自带标点，TTS 停顿更自然；① 不降反升（模型一次性看全文，标点+翻译联合优化比拆开更准）。
- **风险**：低-中。需调整 system prompt 明确"输出带标点译文"。流式断句策略要重新设计：本地启发式（Vosk final + 静默兜底 + 词数/字符数）为主，LLM 不再单独用于断句。
- **影响文件**：`translation_service.dart`（删 punctuate 或保留作降级）、`live_session.dart`（删 _runPunct/_punctTimer/_punctBusy，_onSegment 简化）。
- **是否推荐**：✅ 是，P0。与 3.1 一并实施。

### 3.3【强烈推荐·P0】TTS 同传改为非阻塞队列（直击 S4）
- **为什么**：`await tts.speak` 阻塞翻译循环，连续中文堆积。同传应是"边说边译边读"，朗读不应阻塞下一句识别与翻译。
- **收益**：②③ 连续中文同传流畅度质变；不降 ①。
- **风险**：低。TTS 内部维护队列，新句到达时可选：排队 / 截断当前句 / 智能合并。推荐"排队 + 队列长度上限（超过则丢最旧未读）"。
- **影响文件**：`tts_service.dart`（队列化）、`live_session.dart`（_handleFinal 中文分支不 await，fire-and-forget）。
- **是否推荐**：✅ 是，P0。

### 3.4【推荐·P1】修复 `_runPunct` race + 流式分段重构（直击 S6）
- **为什么**：partial 覆盖式更新与 async 标点返回存在 race，可能丢内容。若采用 3.2（标点+翻译合并），`_runPunct` 整体删除，race 自然消失；若保留则需引入版本号快照。
- **收益**：① 不丢内容；代码大幅简化。
- **风险**：低（若随 3.2 删除）/ 中（若独立修复）。
- **影响文件**：`live_session.dart`。
- **是否推荐**：✅ 随 3.2 一并实施，删除 `_runPunct` 及相关计时器。

### 3.5【推荐·P1】ASR 推 Isolate（直击 S3）
- **为什么**：`_onAudio` 在 UI 线程跑双识别器，高频 native await 抢占 UI。推到 Isolate 可解放 UI 线程，UI 只收最终 onSegment 回调。
- **收益**：③ UI 流畅度显著提升；录音期间不卡顿。
- **风险**：**高**。`vosk_flutter` 插件是否支持在 Isolate 内使用需验证（Recognizer/Model 对象能否跨 isolate、platform channel 是否绑定主 isolate）。若不支持，需回退为"UI 线程 + 限流优化"或"native 侧自建 Isolate（Kotlin 端）"。
- **影响文件**：`vosk_engine.dart`（大幅重构）、可能需新增 native 侧代码。
- **是否推荐**：⚠️ 推荐，但需先做可行性验证（Phase 3 先 spike），不可贸然全改。

### 3.6【推荐·P1】UI rebuild 收窄（直击 M1/M2）
- **为什么**：整页 watch + partial 140ms 刷新，高频 rebuild。
- **收益**：③ UI 流畅。
- **风险**：低。
- **影响文件**：`live_page.dart`（partial 预览用 `Selector<LiveSession, String>` 单独订阅；notes 列表用 `Selector<LiveSession, List<NoteEntry>>`；`addPostFrameCallback` 移到 `initState` 的 listener 或 notes 长度变化监听）。
- **是否推荐**：✅ 是。

### 3.7【推荐·P1】LLM 请求加超时 + 连接复用 + 取消（直击 M3）
- **为什么**：弱网下无限等待，无降级。
- **收益**：③ 稳定性。
- **风险**：低。
- **影响文件**：`translation_service.dart`（`http.Client` 复用 + `.timeout(Duration(seconds: 8))`；流式版本用 `StreamSubscription` 支持取消）。
- **是否推荐**：✅ 是。

### 3.8【推荐·P1】修复手动语种 ChoiceChip 俄语显示（直击 M7）
- **为什么**：俄语模式下手动语种功能失效。
- **收益**：① 语种判别正确。
- **风险**：极低。
- **影响文件**：`live_page.dart`（第三个 chip label 与 value 跟随 `settings.foreignLang`）。
- **是否推荐**：✅ 是。

### 3.9【推荐·P2】`_kMaxWords` 改字符数判断（直击 M10）
- **为什么**：中文按空格分词恒为 1，永不主动提交，中文全靠 1200ms 静默兜底。
- **收益**：③ 中文长独白提前提交，体感更跟手。
- **风险**：极低。
- **影响文件**：`live_session.dart`（改为 `_streamBuffer.replaceAll(RegExp(r'\s+'),'').length >= 24`）。
- **是否推荐**：✅ 是。

### 3.10【推荐·P2】修复 codemagic.yaml 版本冲突（直击 S5）
- **为什么**：Codemagic 路径完全不可用。
- **收益**：构建一致性。
- **风险**：极低。
- **影响文件**：`codemagic.yaml`（flutter 改为 "3.7.12"）。
- **是否推荐**：✅ 是。

### 3.11【推荐·P2】状态改枚举（直击 M6）
- **为什么**：字符串硬编码易错。
- **收益**：编译期保障。
- **风险**：极低。
- **影响文件**：`live_session.dart`、`live_page.dart`。
- **是否推荐**：✅ 是。

### 3.12【推荐·P2】`stop()` 顺序修正（直击 S7）
- **为什么**：停止时仍触发翻译与 TTS，行为怪异。
- **收益**：稳定性、体验。
- **风险**：低。应先取消所有计时器与在途请求，再停 engine 与 tts，最后清缓冲（不触发翻译）。
- **影响文件**：`live_session.dart`。
- **是否推荐**：✅ 是。

### 3.13【可选·P3】`TranslationService` 抽 `_chat` 公共方法（直击 L1）
- **收益**：去重。
- **风险**：极低。
- **影响文件**：`translation_service.dart`。
- **是否推荐**：✅ 是，顺带做。

### 3.14【可选·P3】清理死代码与冗余（直击 L4-L9）
- 删 `TtsService.setVolume`、`SpeechEngine.start.localeId`、`/settings` 死路由、`NoteEntry.time`（或保留备用）、`assets/.gitkeep`、`print`→`debugPrint`。
- **是否推荐**：✅ 是，顺带做。

### 3.15【谨慎·P3】`LiveSession` 拆分
- **为什么**：365 行塞了 6 项职责，违背单一职责。
- **收益**：④ 代码简洁、可测试性。
- **风险**：中。拆分本身不改运行时行为，但涉及状态在多类间流转，易引入 bug。
- **影响文件**：`live_session.dart` 拆为 `SessionController`（生命周期/状态）+ `StreamSegmenter`（分段）+ `TranslationRouter`（路由）。
- **是否推荐**：⚠️ 推荐，但放 Phase 3，且**仅当 3.1-3.4 完成后**再做（流式重构会大幅简化 LiveSession，届时拆分边界更清晰）。

### 3.16【不推荐】`_recentSources` 加锁
- 虽有 M5 顺序问题，但加锁会引入死锁风险。**正确做法是随 3.2/3.3 让翻译串行化（同一句未完成不发起下一句）或用请求序号**，而非加锁。
- **是否推荐**：❌ 不单独做，随 3.2 自然解决。

---

## 四、重构计划

> 原则：每个 Phase 独立可完成，完成后项目仍可正常运行。Phase 间需你确认。
> 优先级严格遵循 ①>②>③>④：Phase 1 先做低风险高收益的稳定性与正确性修复；Phase 2 集中攻克实时性核心（流式+合并+TTS 非阻塞）；Phase 3 做较重的架构优化（Isolate+拆分）。

### Phase 1 — 稳定性与正确性修复（低风险，不动核心架构）

**目标**：消除构建/正确性/稳定性 bug，为 Phase 2 铺路。不改变实时性实现方式。

**步骤**：
1. 修复 `codemagic.yaml` Flutter 版本 → `3.7.12`（S5 / 3.10）
2. 修复手动语种 ChoiceChip 俄语显示（M7 / 3.8）
3. 修复 `_kMaxWords` 中文分词（M10 / 3.9）
4. 修复 `stop()` 顺序：先取消计时器与在途请求 → 停 engine → 停 tts → 清缓冲不触发翻译（S7 / 3.12）
5. 状态字符串改枚举（M6 / 3.11）
6. LLM 请求加 `timeout` + `http.Client` 复用（M3 / 3.7）
7. UI rebuild 收窄：partial 预览与 notes 列表用 `Selector`；`addPostFrameCallback` 移出 build（M1/M2 / 3.6）
8. `TranslationService` 抽 `_chat` 公共方法（L1 / 3.13）
9. 清理死代码：`setVolume` / `localeId` / `/settings` 路由 / `.gitkeep` / `print`→`debugPrint`（L4-L9 / 3.14）

**验收**：
- `flutter analyze` 无 warning。
- 手动验证：英文/俄语/中文三向翻译功能正常；俄语模式手动语种生效；停止按钮不再出现"停了又朗读"。
- 构建配置两份（GH Actions + Codemagic）均可跑通。

**风险**：低。每步独立、可回退。

---

### Phase 2 — 实时性核心重构（中风险，直击 ②③）

**目标**：把"两次串行非流式 LLM"重构为"一次流式 LLM（标点+翻译合一 + SSE 流式输出）"，TTS 改非阻塞队列。这是接近 ChatGPT Voice 体验的关键一步。

**步骤**：
1. `TranslationService.translate` 重写为返回 `Stream<String>`（SSE 解析，逐 token yield），保留 `translateSync` 旧方法作降级（S1 / 3.1）
2. 合并标点与翻译：system prompt 调整为"输入 ASR 原文，输出带自然标点的译文"，删除 `punctuate` 独立调用路径（S2 / 3.2）
3. `LiveSession` 删除 `_runPunct` / `_punctTimer` / `_punctBusy` / `_lastPunctCall` / `_kPunctDebounceMs` / `_kPunctMaxIntervalMs`，流式分段改为：Vosk final 立即提交 + 静默兜底 + 字符数硬上限（S6 / 3.4）
4. `_handleFinal` 改为消费 `Stream<String>`：外语源增量更新 `NoteEntry.translation`（逐字浮现）+ `notifyListeners`；中文源拿到首 token 后 fire-and-forget 触发 TTS
5. `TtsService` 队列化：内部维护待读列表，`speak` 不再 `awaitSpeakCompletion` 阻塞调用方；队列长度上限 3，超过丢最旧未读（S4 / 3.3）
6. `_handleFinal` 中文分支不 `await tts.speak`，翻译循环立即继续
7. 流式请求支持取消（`StreamSubscription.cancel`），stop() 时取消在途翻译
8. 上下文窗口 `_recentSources` 改为按请求序号提交，避免完成顺序错乱（M5 / 3.16）

**验收**：
- 英文源：译文逐字浮现，首字延迟明显低于 Phase 1。
- 中文源：连续说三句中文，三句翻译快速发起，TTS 按队列朗读，不堆积。
- 翻译准确率不降（同模型同温度，prompt 仅合并标点指令）。
- stop() 立即停止，在途流式请求被取消。

**风险**：中。SSE 解析需健壮（处理 `[DONE]`、`data:` 前缀、断流）；UI 逐字刷新频率需控制（节流，避免每个 token 都 rebuild）。需充分手动测试。

---

### Phase 3 — 架构与性能优化（较高风险，需先验证）

**目标**：解放 UI 线程，拆分过重的 LiveSession，提升长期可维护性。**前提：Phase 2 完成且稳定。**

**步骤**：
1. **Spike：验证 `vosk_flutter` 在 Isolate 内的可用性**（3.5）
   - 写最小 demo：在 Isolate 内创建 Model + Recognizer，喂 PCM，回传 partial。
   - 若可行 → 进入步骤 2；若不可行 → 改为"native 侧（Kotlin）自建音频+Vosk 线程"或"UI 线程限流优化"，跳过 Isolate。
2. 将 `VoskEngine` 的 `_onAudio` 双识别器仲裁逻辑迁入 Isolate，UI 线程只收 `onSegment` 回调（通过 SendPort/ReceivePort）（S3 / 3.5）
3. `_onAudio` 内两个识别器 `acceptWaveformBytes` 改 `Future.wait` 并行（若仍在 UI 线程则一并优化）（M4）
4. `LiveSession` 拆分（3.15）：
   - `SessionController`：生命周期（start/stop）、状态机、对外 ChangeNotifier
   - `StreamSegmenter`：partial/final 分段、静默兜底、字符数上限
   - `TranslationRouter`：路由字幕/同传、上下文窗口、TTS 调度
5. 补充单元测试：`StreamSegmenter` 与 `TranslationService` 的核心逻辑（L10）

**验收**：
- 录音期间 UI 滑动流畅（Profiler 显示 UI 线程占用显著下降）。
- 拆分后三类职责清晰，单测覆盖分段逻辑。
- 功能与 Phase 2 完全一致（无回归）。

**风险**：高。Isolate 兼容性是最大未知数，必须先 spike 再决策。若 spike 失败，步骤 2 改为 native 侧方案或放弃，仅做 3/4/5。

---

## 五、待确认事项

1. **Phase 1 是否可以开始？** （低风险稳定性修复，不改实时性架构）
2. **Phase 2 的流式方案是否接受？** （核心收益，但改动较大，需充分测试）
3. **Phase 3 的 Isolate spike 是否纳入？** （高收益高风险，取决于 vosk_flutter 兼容性）
4. 是否保留 `punctuate` 作为降级路径（无网络/流式失败时回退本地断句），还是彻底删除？
5. TTS 队列策略：排队 / 截断当前句 / 智能合并，倾向哪种？（默认推荐：排队 + 上限 3 丢最旧）

---

> 请确认后，我将从 Phase 1 开始，**一次只完成一个 Phase，每个 Phase 完成后再次等待你确认**。
> 未经你确认，不修改任何源码。
