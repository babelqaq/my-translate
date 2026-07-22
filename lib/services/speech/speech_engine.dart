/// 统一的语音识别引擎接口。
///
/// [onSegment] 回调参数：
/// - [text]    识别出的文本
/// - [isFinal] 是否为整句结束（false 为流式 partial）
/// - [lang]    语种：'en' | 'zh' | 'ru'
abstract class SpeechEngine {
  String get name;

  /// [foreignLang] 当前选择的外语（'en' 或 'ru'），用于：
  /// - Vosk：决定加载哪个外语离线模型
  /// - Google：决定监听哪种外语 locale
  Future<void> initialize({
    void Function(String status)? onStatus,
    String? foreignLang,
  });

  Future<void> start({
    required void Function(String text, bool isFinal, String lang) onSegment,
    String? localeId,
  });

  Future<void> stop();
}
