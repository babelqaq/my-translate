import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class TtsService extends ChangeNotifier {
  final FlutterTts _tts = FlutterTts();
  bool _speaking = false;
  Timer? _resumeTimer;

  /// TTS 播放结束后的冷却期（毫秒）：避开扬声器尾音与传播/采集延迟造成的回声残留。
  static const int _echoCooldownMs = 400;

  /// 外部注入：TTS 开始 / 结束时通知采集层静音（防回声自触发）。
  void Function()? onSpeakStart;
  void Function()? onSpeakEnd;

  bool get speaking => _speaking;

  TtsService() {
    _tts.setStartHandler(() {
      _speaking = true;
      notifyListeners();
    });

    _tts.setCompletionHandler(() {
      _speaking = false;
      notifyListeners();
      _scheduleResume();
    });

    _tts.setErrorHandler((msg) {
      _speaking = false;
      notifyListeners();
      debugPrint('TTS error: $msg');
      _scheduleResume();
    });
  }

  /// 朗读文本
  Future<void> speak(String text, {String? language}) async {
    if (text.isEmpty) return;

    await _tts.awaitSpeakCompletion(true);

    if (language != null) {
      await _tts.setLanguage(language);
    }

    // 防回声自触发：播放前暂停麦克风采集；若紧接着又是一段 TTS，保持静音。
    _resumeTimer?.cancel();
    onSpeakStart?.call();

    final result = await _tts.speak(text);
    if (result == 1) {
      _speaking = true;
      notifyListeners();
    }
  }

  /// 停止朗读
  Future<void> stop() async {
    await _tts.stop();
    _speaking = false;
    _scheduleResume();
    notifyListeners();
  }

  /// TTS 结束后延迟恢复采集，避开扬声器尾音与传播/采集延迟。
  void _scheduleResume() {
    _resumeTimer?.cancel();
    _resumeTimer = Timer(
      Duration(milliseconds: _echoCooldownMs),
      () => onSpeakEnd?.call(),
    );
  }

  /// 设置语速 (0.0 ~ 1.0)
  Future<void> setSpeed(double speed) async {
    await _tts.setSpeechRate(speed);
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    _tts.stop();
    super.dispose();
  }
}
