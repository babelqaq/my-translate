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
/// 外语来源(en/ru) -> 中文滚动词幕（不朗读）
/// 中文来源 -> 翻译成外语并 TTS 同声传译（不落字幕）
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

  /// 按语种累积 final 的缓冲区：攒成更完整的句段再翻译，
  /// 避免 Vosk 在停顿处把长句拆成多段各自翻译而丢失上下文。
  String _accumText = '';
  String _accumLang = '';
  Timer? _silenceTimer;

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

  /// 口语中的语气词 / 无意义填充词；去除后若为空则视为无内容。
  static const Set<String> _fillers = {
    '啊', '呀', '嗯', '呃', '诶', '哎', '哦', '喂',
    '那个', '这个', '就是', '然后', '的话', '对吧', '是不是',
    'um', 'uh', 'er', 'ah', 'oh', 'well', 'like', 'mm',
  };

  /// 判断识别结果是否为「无语义内容」（纯语气词 / 标点 / 噪声）。
  /// 用于没说话或仅有 filler 时，避免触发翻译与同传朗读。
  static bool _isMeaningless(String text) {
    final t = text.trim().toLowerCase();
    // 去掉所有标点与空白后为空 -> 无意义
    final stripped = t.replaceAll(RegExp(r'[\s\p{P}]+', unicode: true), '');
    if (stripped.isEmpty) return true;
    // 逐个去掉已知填充词后若为空 -> 无意义（纯语气词）
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

    _engine = settings.engine == 'google' ? GoogleEngine() : VoskEngine();
    if (_engine is VoskEngine) {
      (_engine as VoskEngine).modelBaseUrl = settings.modelBaseUrl;
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

  /// 识别回调入口。
  /// partial：仅更新预览字幕，不翻译。
  /// final：按语种累积到缓冲区，攒成完整句段后再翻译——
  ///   触发翻译的时机：① 语种切换；② 出现句末标点；③ 静默超过阈值。
  void _onSegment(String text, bool isFinal, String lang) {
    if (text.trim().isEmpty) return;
    if (!isFinal) {
      _partial = text;
      _partialLang = lang;
      notifyListeners();
      return;
    }
    _partial = '';
    _partialLang = '';

    // 语种切换：先把上一语种攒下的内容翻译出来
    if (_accumLang.isNotEmpty && _accumLang != lang) {
      _flushAccum();
    }
    _accumLang = lang;
    _accumText = _accumText.isEmpty ? text.trim() : '$_accumText ${text.trim()}';

    // 句末标点 -> 视为一句结束，立即翻译
    if (_hasSentenceEnd(_accumText)) {
      _flushAccum();
      return;
    }
    // 否则重置静默计时器：超过阈值无新 final 也认为该句结束
    _silenceTimer?.cancel();
    _silenceTimer = Timer(const Duration(milliseconds: 1800), () {
      if (_accumText.trim().isNotEmpty) _flushAccum();
    });
  }

  /// 是否包含句末标点（中英文句末 + 省略号）。
  static bool _hasSentenceEnd(String t) =>
      t.trim().contains(RegExp(r'[。.!?！？…]"));

  /// 把缓冲区里攒好的完整句段交给翻译/同传处理，并清空缓冲。
  void _flushAccum() {
    final text = _accumText.trim();
    final lang = _accumLang;
    _accumText = '';
    _accumLang = '';
    _silenceTimer?.cancel();
    _silenceTimer = null;
    if (text.isEmpty) return;
    _handleFinal(text, lang);
  }

  Future<void> _handleFinal(String text, String lang) async {
    // 拦截纯语气词 / 噪声 / 无意义识别结果：不翻译、不同传朗读。
    if (_isMeaningless(text)) return;
    try {
      if (lang == 'zh') {
        // 中文来源 -> 翻译成外语并同声传译
        final foreign = await translation.translate(
          text,
          source: 'zh',
          target: settings.foreignLang,
          isSpeech: true,
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
    }
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
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _flushAccum(); // 把停顿末尾攒下的最后一句也翻译出来
    _setStatus('idle', '已停止');
  }

  void clearNotes() {
    _notes.clear();
    notifyListeners();
  }

  void _setStatus(String s, String text) {
    _status = s;
    _statusText = text;
    notifyListeners();
  }

  @override
  void dispose() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _engine?.stop();
    super.dispose();
  }
}
