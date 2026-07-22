import 'package:flutter/foundation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'speech_engine.dart';

/// 在线识别引擎：封装 speech_to_text（设备上的 Google 语音服务）。
/// 需要固定语种（localeId），因为 Google 识别器不自动判别中英文。
class GoogleEngine implements SpeechEngine {
  final stt.SpeechToText _speech = stt.SpeechToText();
  bool _ready = false;
  String _foreignLang = 'en';

  @override
  String get name => 'google';

  @override
  Future<void> initialize({
    void Function(String status)? onStatus,
    String? foreignLang,
  }) async {
    _foreignLang = foreignLang ?? 'en';
    onStatus?.call('正在初始化 Google 语音识别…');
    _ready = await _speech.initialize(
      onStatus: (s) => debugPrint('[google] $s'),
      onError: (e) => debugPrint('[google] $e'),
    );
    if (!_ready) {
      throw Exception('Google 语音识别不可用（需联网且设备已安装 Google 服务）');
    }
  }

  @override
  Future<void> start({
    required void Function(String text, bool isFinal, String lang) onSegment,
    String? localeId,
  }) async {
    if (!_ready) await initialize(foreignLang: _foreignLang);
    // Google 单语种识别：监听用户选择的外语（俄语或英语）。
    // 注意：因此「听中文 → 外语同传」方向在 Google 引擎下不会触发，
    // 如需双向自动判别，请使用默认的 Vosk 离线引擎。
    final loc = localeId ?? (_foreignLang == 'ru' ? 'ru-RU' : 'en-US');
    final lang = loc.toLowerCase().startsWith('zh') ? 'zh' : _foreignLang;
    await _speech.listen(
      onResult: (result) {
        if (result.recognizedWords.trim().isNotEmpty) {
          onSegment(result.recognizedWords, result.finalResult, lang);
        }
      },
      localeId: loc,
      partialResults: true,
      listenMode: stt.ListenMode.dictation,
    );
  }

  @override
  Future<void> stop() async {
    await _speech.stop();
  }
}
