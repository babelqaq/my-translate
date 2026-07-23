import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'speech/speech_engine.dart';
import 'speech/vosk_engine.dart';
import 'speech/google_engine.dart';
import 'translation_service.dart';
import 'tts_service.dart';
import 'app_settings.dart';

class NoteEntry {
  final String source;
  final String translation;
  final String sourceLang; // 'en' | 'zh' | 'ru'
  final DateTime time;
  NoteEntry({
    required this.source,
    required this.translation,
    required this.sourceLang,
    required this.time,
  });
}

/// 编排：监听 -> 语种判断 -> 翻译 -> 路由
/// 外语来源(en/ru) -> 中文滚动字幕（不朗读）
/// 中文来源 -> 翻译成外语并 TTS 同声传译（不落字幕）
///
/// 流式分段：Vosk 等 ASR 输出不带标点，本类用「AI 自动加标点 + 句末切分」
/// 实现「每个句号翻译/同传一次」的流式体验——partial 持续累积，防抖调用 LLM
/// 补全标点，一旦出现句号即把已完成的一句提交翻译，无需等整段停顿。
class LiveSession extends ChangeNotifier {
  final AppSettings settings;
  final TranslationService translation;
  final TtsService tts;

  SpeechEngine? _engine;
  List<NoteEntry> _notes = [];
  String _status = 'idle'; // idle | loading | listening | error
  String _statusText = '准备就绪';
  String _partial = '';
  String _partialLang = '';
  String _message = '';

  /// 手动语种提示：'en' | 'zh' | null(自动)。由界面按钮设置，
  /// 强制 Vosk 引擎采用对应识别器，绕过自动判别（解决中文被误识别成英文）。
  String? _manualLang;

  /// 流式缓冲：当前正在累积、尚未翻译的源文。
  /// 覆盖式更新自 Vosk partial（getPartialResult 返回「到目前为止的全部假设」，
  /// 是全量而非增量），final 来时合并进缓冲并立即提交。
  String _streamBuffer = '';
  String _streamLang = '';

  /// 标点防抖/周期计时器：partial 稳定后（或周期到点）调用 LLM 加标点并断句。
  Timer? _punctTimer;
  bool _punctBusy = false;
  DateTime _lastPunctCall = DateTime.fromMillisecondsSinceEpoch(0);

  /// 静默兜底计时器：超过该时长无任何新识别，把缓冲整段当一句提交。
  Timer? _silenceTimer;

  /// 标点防抖：说话停顿超过该值才去问 LLM（避免每个 partial 都打 API）。
  static const int _kPunctDebounceMs = 400;
  /// 标点周期：即便一直在说（无停顿），也至少每这么久主动问一次 LLM 是否有句号。
  static const int _kPunctMaxIntervalMs = 1500;
  /// 静默提交窗口：超过该时长无任何新识别即认为一句话结束。
  static const int _kCommitMs = 1200;
  /// 缓冲区单词数软上限：长到一定程度即主动提交，避免长独白积压成一条。
  static const int _kMaxWords = 28;

  /// 对话上下文窗口：最近若干句原文，传给 LLM 帮助消歧（上限 8，取最近 4）。
  final List<String> _recentSources = [];

  LiveSession({
    required this.settings,
    required this.translation,
    required this.tts,
  });

  List<NoteEntry> get notes => _notes;
  String get status => _status;
  String get statusText => _statusText;
  String get partial => _partial;
  String get partialLang => _partialLang;
  String get message => _message;
  /// 当前手动语种模式：'auto' | 'en' | 'zh'。
  String get manualLang => _manualLang ?? 'auto';

  /// 口语中的语气词 / 无意义填充词；去除后若为空则视为无内容。
  static const Set<String> _fillers = {
    '啊', '呀', '嗯', '呃', '诶', '哎', '哦', '喂',
    '那个', '这个', '就是', '然后', '的话', '对吧', '是不是',
    'um', 'uh', 'er', 'ah', 'oh', 'well', 'like', 'mm',
  };

  /// 判断识别结果是否为「无语义内容」（纯语气词 / 标点 / 噪声）。
  static bool _isMeaningless(String text) {
    final t = text.trim().toLowerCase();
    final stripped = t.replaceAll(RegExp(r'[\s\p{P}]+', unicode: true), '');
    if (stripped.isEmpty) return true;
    var remaining = t;
    for (final f in _fillers) {
      remaining = remaining.replaceAll(f, '');
    }
    final after = remaining.replaceAll(RegExp(r'[\s\p{P}]+', unicode: true), '');
    return after.isEmpty;
  }

  Future<void> start() async {
    if (_status == 'listening' || _status == 'loading') return;

    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _setStatus('error', '需要麦克风权限才能使用');
      return;
    }

    _recentSources.clear(); // 新会话从干净上下文开始
    _streamBuffer = '';
    _streamLang = '';

    _engine = settings.engine == 'google' ? GoogleEngine() : VoskEngine();
    if (_engine is VoskEngine) {
      final v = _engine as VoskEngine;
      v.modelBaseUrl = settings.modelBaseUrl;
      v.preferredLang = _manualLang; // 恢复上次手动语种选择
    }
    _setStatus('loading', '正在准备识别引擎…');

    try {
      await _engine!.initialize(
        onStatus: (s) => _setStatus('loading', s),
        foreignLang: settings.foreignLang,
      );
    } catch (e) {
      _setStatus('error', '引擎初始化失败：$e');
      _engine = null;
      return;
    }

    await tts.setSpeed(settings.ttsRate);
    _setStatus('listening', '监听中…');

    try {
      await _engine!.start(
        onSegment: _onSegment,
      );
    } catch (e) {
      _setStatus('error', '启动识别失败：$e');
    }
  }

  /// 识别回调入口（流式分段核心）。
  /// - partial：覆盖式更新缓冲与预览，并（重新）启动标点防抖 + 静默兜底计时器；
  ///   防抖到期由 LLM 加标点并切出「已有句号的一句」提交翻译。
  /// - final：识别器判定确定边界，合并进缓冲并立即整句提交（翻译 LLM 自行加标点）。
  /// - 语种切换：先把上一语种缓冲当一句提交，再接管新语种。
  void _onSegment(String text, bool isFinal, String lang) {
    if (text.trim().isEmpty) return;

    // 语种切换：先把上一语种攒下的内容当一句提交
    if (_streamLang.isNotEmpty && _streamLang != lang && _streamBuffer.trim().isNotEmpty) {
      _flushStream();
    }

    if (isFinal) {
      // final = 识别器判定一个确定边界：合并进缓冲并立即提交整句。
      _streamLang = lang;
      _streamBuffer = _streamBuffer.isEmpty
          ? text.trim()
          : '$_streamBuffer ${text.trim()}';
      _flushStream();
      return;
    }

    // partial：覆盖式更新当前全量假设，并刷新预览。
    _streamLang = lang;
    _streamBuffer = text.trim();
    _partial = text;
    _partialLang = lang;
    notifyListeners();

    // 过长主动提交，避免积压成一条巨句。
    if (_streamBuffer.split(RegExp(r'\s+')).length >= _kMaxWords) {
      _flushStream();
      return;
    }
    _armPunctTimer();
    _armSilenceTimer();
  }

  /// 重新启动「标点」计时器（partial 调用）：
  /// 若距上次问 LLM 已超过周期，立即检查句号；否则防抖 400ms 后再问。
  void _armPunctTimer() {
    _punctTimer?.cancel();
    final since = DateTime.now().difference(_lastPunctCall).inMilliseconds;
    if (since >= _kPunctMaxIntervalMs) {
      _runPunct();
    } else {
      _punctTimer = Timer(
        const Duration(milliseconds: _kPunctDebounceMs),
        _runPunct,
      );
    }
  }

  /// 调用 LLM 为当前缓冲加标点，并按「最后一个句号」切出已完成的一句提交翻译；
  /// 句号之后的半句留在缓冲，等下一轮 partial 或静默兜底。
  Future<void> _runPunct() async {
    if (_punctBusy) return;
    if (_streamBuffer.trim().isEmpty) return;
    _punctBusy = true;
    _lastPunctCall = DateTime.now();
    try {
      final p = await translation.punctuate(_streamBuffer, _streamLang);
      final cut = _lastSentenceEnd(p);
      if (cut >= 0) {
        final sentence = p.substring(0, cut + 1).trim();
        final rest = p.substring(cut + 1).trim();
        _streamBuffer = rest; // 句号之后的半句留待下轮
        if (sentence.isNotEmpty) {
          _handleFinal(sentence, _streamLang);
        }
      }
      // 没找到句号：保持缓冲，等下一个 partial 或静默兜底。
    } catch (_) {
      // 标点失败不阻断：退化交给静默兜底整段翻译。
    } finally {
      _punctBusy = false;
    }
  }

  /// 返回文本中最后一个句末标点的索引；无则 -1。
  static int _lastSentenceEnd(String t) {
    const marks = '。.!?！？';
    var idx = -1;
    for (var i = 0; i < t.length; i++) {
      if (marks.contains(t[i])) idx = i;
    }
    return idx;
  }

  /// 重新启动「静默兜底」计时器（partial 与 final 都重置它）。
  void _armSilenceTimer() {
    _silenceTimer?.cancel();
    _silenceTimer = Timer(const Duration(milliseconds: _kCommitMs), _onSilence);
  }

  /// 静默到期：把缓冲整段当一句提交（可能无句号，翻译 LLM 会自行加标点）。
  void _onSilence() {
    _silenceTimer = null;
    if (_streamBuffer.trim().isNotEmpty) _flushStream();
  }

  /// 把当前缓冲整段当一句提交翻译/同传，并清空缓冲与计时器。
  void _flushStream() {
    _punctTimer?.cancel();
    _punctTimer = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    final text = _streamBuffer.trim();
    final lang = _streamLang;
    _streamBuffer = '';
    _streamLang = '';
    if (text.isNotEmpty) _handleFinal(text, lang);
  }

  Future<void> _handleFinal(String text, String lang) async {
    // 拦截纯语气词 / 噪声 / 无意义识别结果：不翻译、不同传朗读。
    if (_isMeaningless(text)) return;
    // 取最近若干句原文作为上下文（不含当前句）
    final ctx = _recentSources.length > 4
        ? _recentSources.sublist(_recentSources.length - 4)
        : List<String>.from(_recentSources);
    try {
      if (lang == 'zh') {
        // 中文来源 -> 翻译成外语并同声传译
        final foreign = await translation.translate(
          text,
          source: 'zh',
          target: settings.foreignLang,
          isSpeech: true,
          context: ctx,
        );
        if (foreign.trim().isEmpty) return; // 模型判定无意义，跳过朗读
        _message = '🔊 同传：$foreign';
        notifyListeners();
        final ttsLang = settings.foreignLang == 'ru' ? 'ru-RU' : 'en-US';
        await tts.speak(foreign, language: ttsLang);
      } else {
        // 外语来源(en/ru) -> 翻译成中文大字幕（不朗读）
        final zh = await translation.translate(
          text,
          source: lang,
          target: 'zh',
          isSpeech: true,
          context: ctx,
        );
        if (zh.trim().isEmpty) return;
        _notes.add(NoteEntry(
          source: text,
          translation: zh,
          sourceLang: lang,
          time: DateTime.now(),
        ));
        notifyListeners();
      }
    } catch (e) {
      _message = '翻译失败：$e';
      notifyListeners();
      return;
    }
    // 翻译成功后把当前原文加入上下文窗口
    _recentSources.add(text);
    if (_recentSources.length > 8) _recentSources.removeAt(0);
  }

  Future<void> stop() async {
    try {
      await _engine?.stop();
    } catch (_) {}
    try {
      await tts.stop();
    } catch (_) {}
    _engine = null;
    _partial = '';
    _partialLang = '';
    _punctTimer?.cancel();
    _punctTimer = null;
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _flushStream(); // 把缓冲里最后一句翻译出来
    _setStatus('idle', '已停止');
  }

  void clearNotes() {
    _notes.clear();
    notifyListeners();
  }

  /// 设置手动语种提示（'en' / 'zh' / 'auto'）。
  /// 即时转发给 Vosk 引擎；切换前先把当前缓冲按旧语言提交，避免混淆。
  void setManualLang(String? lang) {
    if (_streamBuffer.trim().isNotEmpty) _flushStream();
    _manualLang = (lang == null || lang == 'auto') ? null : lang;
    if (_engine is VoskEngine) {
      (_engine as VoskEngine).preferredLang = _manualLang;
    }
    notifyListeners();
  }

  void _setStatus(String s, String text) {
    _status = s;
    _statusText = text;
    notifyListeners();
  }

  @override
  void dispose() {
    _punctTimer?.cancel();
    _silenceTimer?.cancel();
    _engine?.stop();
    super.dispose();
  }
}
