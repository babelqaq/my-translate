import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

class TtsService extends ChangeNotifier {
  final FlutterTts _tts = FlutterTts();
  bool _speaking = false;

  bool get speaking => _speaking;

  TtsService() {
    _tts.setStartHandler(() {
      _speaking = true;
      notifyListeners();
    });

    _tts.setCompletionHandler(() {
      _speaking = false;
      notifyListeners();
    });

    _tts.setErrorHandler((msg) {
      _speaking = false;
      notifyListeners();
      debugPrint('TTS error: $msg');
    });
  }

  /// 朗读文本
  Future<void> speak(String text, {String? language}) async {
    if (text.isEmpty) return;

    await _tts.awaitSpeakCompletion(true);

    if (language != null) {
      await _tts.setLanguage(language);
    }

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
    notifyListeners();
  }

  /// 设置语速 (0.0 ~ 1.0)
  Future<void> setSpeed(double speed) async {
    await _tts.setSpeechRate(speed);
  }

  @override
  void dispose() {
    _tts.stop();
    super.dispose();
  }
}
