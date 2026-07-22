# 语音翻译助手（Android）— 实现总览

## 你要的功能
- 点「开始」后持续听音，**自动判别语种**（外语 ↔ 中文）：
  - 听到**外语（英文 / 俄语，可在设置切换）** → 屏幕生成**大字号、可滚动的笔记式中文字幕**（不朗读）
  - 听到**中文** → **流式同声传译**：把外语翻译结果用 TTS 朗读出来（不落字幕，仅显示同传反馈）
- 界面极简：状态条 + 大字幕区 + 一个大开始/停止按钮
- 个人使用，免费（国内大模型翻译，无需外币信用卡）

## 外语切换
- 设置里提供「英文 / 俄语」单选：
  - 选 **英文**：听英文 → 中文字幕；听中文 → 英文同传
  - 选 **俄语**：听俄语 → 中文字幕；听中文 → 俄语同传

## 技术方案（已落地）
- **平台**：Flutter（Dart）targeting Android，复用你已有的工程脚手架
- **离线识别（默认）**：`vosk_flutter` 同时加载「外语 + 中文」两个小模型（英文 en-us / 俄语 ru / 中文 cn），用 `flutter_sound` 采集一路 PCM 同时喂两个识别器，按哪路有有效文本自动判别语种 → 真正免 Key、可离线
- **在线识别（开关）**：`speech_to_text`（设备 Google 语音服务），在「设置」里切换；单语种，监听所选外语，需联网
- **翻译**：国内大模型（OpenAI 兼容 Chat 接口：智谱 GLM `glm-4-flash` / 通义千问 `qwen-turbo` / 豆包），支持任意语种对（EN/ZH/RU），无需外币信用卡，Key 在设置中填写
- **同传朗读**：`flutter_tts`（英文 en-US / 俄语 ru-RU）
- **设置持久化**：`shared_preferences`（引擎、外语、翻译供应商/Key/模型、语速、字幕字号）

## 关键文件
- `lib/services/live_session.dart`：核心编排（监听→判别→翻译→路由字幕/同传）
- `lib/services/speech/vosk_engine.dart`：Vosk 双模型离线引擎（按外语加载模型）
- `lib/services/speech/google_engine.dart`：Google 在线引擎（按外语推导 locale）
- `lib/services/translation_service.dart`：国内大模型翻译（OpenAI 兼容接口）
- `lib/pages/live_page.dart`：主界面（大字幕 + 开始/停止）
- `lib/pages/settings_page.dart`：设置（外语切换、引擎、翻译供应商/Key/模型、语速、字号）
- `lib/services/app_settings.dart`：设置项与持久化

## 如何跑起来
见 `BUILD.md`：本仓库只含源码，需在你机器上 `flutter create .` 生成平台工程 → 加权限 → `flutter pub get` → `flutter build apk`。

## 已知权衡
- Vosk 准确率低于云端，但免费/离线/自动判别，契合个人需求；想要更准可在设置切 Google（需联网）
- 国内大模型均有免费额度（GLM `glm-4-flash` 免费 / 千问 `qwen-turbo` 送额度），个人足够；Key 在对应平台注册获取
- Google 引擎为单语种，只监听所选外语，「听中文 → 同传」方向不会触发（Vosk 支持双向）
- 沙箱无 Flutter/SDK，未能在此编译 APK，仅交付完整源码 + 构建说明
