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

  Future<void> start() async {
    if (_status == 'listening' || _status == 'loading') return;

    final mic = await Permission.microphone.request();
    if (!mic.isGranted) {
      _setStatus('error', '需要麦克风权限才能使用');
      return;
    }

    _engine = settings.engine == 'google' ? GoogleEngine() : VoskEngine();
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
    _handleFinal(text, lang);
  }

  Future<void> _handleFinal(String text, String lang) async {
    try {
      if (lang == 'zh') {
        // 中文来源 -> 翻译成外语并同声传译
        final foreign =
            await translation.translate(text, source: 'zh', target: settings.foreignLang);
        _message = '🔊 同传：$foreign';
        notifyListeners();
        final ttsLang = settings.foreignLang == 'ru' ? 'ru-RU' : 'en-US';
        await tts.speak(foreign, language: ttsLang);
      } else {
        // 外语来源(en/ru) -> 翻译成中文大字幕（不朗读）
        final zh = await translation.translate(text, source: lang, target: 'zh');
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
    _engine?.stop();
    super.dispose();
  }
}
