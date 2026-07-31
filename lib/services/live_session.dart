import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'speech/native_asr_engine.dart';
import 'translation_router.dart';
import 'translation_service.dart';
import 'tts_service.dart';
import 'app_settings.dart';

/// 会话状态机。
enum SessionStatus { idle, loading, listening, error }

/// 字幕条目：原文 + 译文 + 源语言。
class NoteEntry {
  final String source;
  final String translation;
  final String sourceLang; // 'en' | 'zh' | 'ru'
  NoteEntry({
    required this.source,
    required this.translation,
    required this.sourceLang,
  });
}

/// 会话编排：ASR 事件 → 语种路由 → 翻译 → 分发（字幕 / TTS）。
///
/// Phase A 重构：切句职责全部移交原生 VAD（Kotlin 层），
/// Dart 侧不再有任何标点防抖 / 静默兜底 / 缓冲上限逻辑。
///
/// 非对称 TTS [INV-TTS]：
/// - source=zh → 翻译成外语并朗读（手机替你说）
/// - source=en/ru → 翻译成中文大字幕，静音（你看字）
class LiveSession extends ChangeNotifier {
  final AppSettings settings;
  final TranslationService translation;
  final TtsService tts;
  final NativeAsrEngine _engine = NativeAsrEngine();

  List<NoteEntry> _notes = [];
  SessionStatus _status = SessionStatus.idle;
  String _statusText = '准备就绪';
  String _partial = '';
  String _message = '';

  /// 手动语种：null/'auto' = 自动；'zh'/'en'/'ru' = 强制。
  /// 两种模式均有（INV-MANUAL）。模式 A 只作用于 Dart route；模式 B 还下发 Kotlin。
  String _manualLang = 'auto';

  /// sticky 语言：字符集判别失败时的兜底。
  String _stickyLang = '';

  LiveSession({
    required this.settings,
    required this.translation,
    required this.tts,
  });

  // ---------- Getters ----------
  List<NoteEntry> get notes => _notes;
  SessionStatus get status => _status;
  String get statusText => _statusText;
  String get partial => _partial;
  String get message => _message;
  String get manualLang => _manualLang;

  /// 当前模式：'zhEn' | 'zhRu'
  String get mode => settings.mode;

  // ---------- 会话控制 ----------

  Future<void> start() async {
    if (_status == SessionStatus.listening || _status == SessionStatus.loading) return;

    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _setStatus(SessionStatus.error, '需要麦克风权限才能使用');
      return;
    }

    _setStatus(SessionStatus.loading, '正在加载模型…');

    // 订阅 ASR 事件
    _engine.subscribe(_onAsrEvent);

    try {
      await _engine.start(mode);
    } catch (e) {
      _setStatus(SessionStatus.error, '启动识别失败：$e');
      _engine.unsubscribe();
    }
  }

  Future<void> stop() async {
    // 1) 停引擎（Kotlin 侧会冲刷尾部 final）
    try {
      await _engine.stop();
    } catch (_) {}
    _engine.unsubscribe();

    // 2) 停 TTS
    try {
      await tts.stop();
    } catch (_) {}

    _partial = '';
    _setStatus(SessionStatus.idle, '已停止');
  }

  // ---------- ASR 事件处理 ----------

  void _onAsrEvent(AsrEvent e) {
    switch (e.type) {
      case 'ready':
        _setStatus(SessionStatus.listening, '监听中');
        break;
      case 'status':
        _statusText = e.text;
        notifyListeners();
        break;
      case 'partial':
        _partial = e.text;
        notifyListeners();
        break;
      case 'final':
        _partial = '';
        _handleFinal(e.text);
        break;
      case 'error':
        _setStatus(SessionStatus.error, e.text);
        break;
    }
  }

  // ---------- 翻译与分发 ----------

  Future<void> _handleFinal(String text) async {
    if (text.trim().isEmpty) return;

    // 语种路由：手动 Chip 优先 > 字符集自动判定
    // stickyLang 透传给 route()，实现 §8.2 第7步 INV-STICKY-SHORT 短文本保护
    final r = TranslationRouter.route(
      text,
      mode,
      manualLang: _manualLang,
      stickyLang: _stickyLang.isEmpty ? null : _stickyLang,
    );
    final SrcLang source;
    final String target;

    if (r != null) {
      source = r.source;
      target = r.target;
      _stickyLang = r.source.name; // 更新 sticky
    } else if (_stickyLang.isNotEmpty) {
      // 字符集模糊，用 sticky 兜底
      source = SrcLang.values.byName(_stickyLang);
      target = TranslationRouter.targetOf(source, mode);
    } else {
      // 无 sticky（首句就模糊），默认按外语处理
      source = mode == 'zhRu' ? SrcLang.ru : SrcLang.en;
      target = 'zh';
    }

    final sourceCode = source.name; // 'zh' | 'en' | 'ru'

    try {
      final translated = await this.translation.translate(sourceCode, target, text);
      if (translated.trim().isEmpty) return; // 模型判定无意义

      if (source == SrcLang.zh) {
        // 中文来源 → 翻译成外语并朗读 [INV-TTS]
        _message = '🔊 同传：$translated';
        notifyListeners();
        final ttsLang = target == 'ru' ? 'ru-RU' : 'en-US';
        await tts.speak(translated, language: ttsLang);
      } else {
        // 外语来源 → 翻译成中文大字幕，静音 [INV-TTS]
        _message = '';
        _notes = [
          ..._notes,
          NoteEntry(
            source: text,
            translation: translated,
            sourceLang: sourceCode,
          ),
        ];
        notifyListeners();
      }
    } catch (e) {
      _message = '翻译失败：$e';
      notifyListeners();
    }
  }

  // ---------- 手动语种 ----------

  /// 设置手动语种 Chip。
  /// 模式 A：只设置 _manualLang（作用于 Dart route）。
  /// 模式 B：还下发 engine.setActiveLang（切 Kotlin 活跃识别器）。
  void setManualLang(String lang) {
    _manualLang = lang;
    if (mode == 'zhRu') {
      _engine.setActiveLang(lang);
    }
    notifyListeners();
  }

  // ---------- 模式切换 ----------

  /// 切换模式（中⇄英 / 中⇄俄）。如果正在运行，先停止。
  Future<void> setMode(String newMode) async {
    if (_status == SessionStatus.listening || _status == SessionStatus.loading) {
      await stop();
    }
    await settings.setMode(newMode);
    _manualLang = 'auto';
    _stickyLang = '';
    notifyListeners();
  }

  // ---------- 字幕管理 ----------

  void clearNotes() {
    _notes = [];
    notifyListeners();
  }

  // ---------- 内部 ----------

  void _setStatus(SessionStatus s, String text) {
    _status = s;
    _statusText = text;
    notifyListeners();
  }

  @override
  void dispose() {
    _engine.unsubscribe();
    _engine.dispose();
    super.dispose();
  }
}
