/// 翻译路由：根据 ASR final 文本和模式，判定源语言与目标语言。
///
/// 这是全 App 语言判定的**唯一**语义实现。
/// Kotlin 侧 charMatch 只是同规则的机械兜底副本（模式 B）。
///
/// 优先级：manualLang（手动 Chip，两种模式均有）> 字符集自动判定。
/// 字符集统计：CJK → zh、西里尔 → ru、拉丁 → en。
/// 三种字符集完全不重叠，故字符集判据在 zh/en/ru 场景下近乎确定性。

enum SrcLang { zh, en, ru }

class RouteResult {
  final SrcLang source;
  final String target; // 'en' | 'ru' | 'zh'

  const RouteResult({required this.source, required this.target});
}

class TranslationRouter {
  /// 字符集"主导"判定比例（与 Kotlin AsrConfig.charDominance 同值）
  static const double _charDominance = 0.6;

  /// 语种名称（用于翻译 Prompt 填充）
  static const Map<String, String> langNames = {
    'en': 'English',
    'zh': 'Chinese',
    'ru': 'Russian',
  };

  /// 路由：final 文本 + 模式 + 手动语种 → 源/目标语言。
  ///
  /// [text]       ASR final 文本
  /// [mode]       'zhEn' | 'zhRu'
  /// [manualLang] 手动 Chip：null/'auto' = 自动；'zh'/'en'/'ru' = 强制
  ///
  /// 返回 null 表示文本无法判别语言（纯数字/标点），调用方按 sticky 处理。
  static RouteResult? route(String text, String mode, {String? manualLang}) {
    // 1. 手动优先
    if (manualLang != null && manualLang != 'auto') {
      final src = _parseLang(manualLang);
      if (src != null) {
        return RouteResult(source: src, target: targetOf(src, mode));
      }
    }

    // 2. 字符集自动判定
    final src = _detectByCharset(text);
    if (src == null) return null; // 模糊，调用方 fallback
    return RouteResult(source: src, target: _targetOf(src, mode));
  }

  /// 根据源语言和模式确定目标语言。
  static String targetOf(SrcLang source, String mode) {
    switch (mode) {
      case 'zhEn':
        return source == SrcLang.zh ? 'en' : 'zh';
      case 'zhRu':
        return source == SrcLang.zh ? 'ru' : 'zh';
      default:
        return 'zh'; // 安全兜底
    }
  }

  /// 字符集统计：CJK / 西里尔 / 拉丁 主导判定。
  static SrcLang? _detectByCharset(String text) {
    if (text.trim().isEmpty) return null;

    int cjk = 0, cyrillic = 0, latin = 0, other = 0;
    for (final ch in text.runes) {
      if (ch >= 0x4E00 && ch <= 0x9FFF) {
        cjk++;
      } else if (ch >= 0x0400 && ch <= 0x04FF) {
        cyrillic++;
      } else if ((ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A)) {
        latin++;
      } else if (_isLetter(ch)) {
        other++;
      }
    }

    final total = cjk + cyrillic + latin + other;
    if (total == 0) return null;

    if (cjk / total >= _charDominance) return SrcLang.zh;
    if (cyrillic / total >= _charDominance) return SrcLang.ru;
    if (latin / total >= _charDominance) return SrcLang.en;

    // 无主导字符集（混说/短词/数字），返回 null 由调用方 sticky fallback
    return null;
  }

  static bool _isLetter(int ch) {
    // Unicode 字母（排除上面已计数的 CJK/西里尔/拉丁 ASCII）
    return (ch >= 0x00C0 && ch <= 0x024F) || // 拉丁扩展
        (ch >= 0x0370 && ch <= 0x03FF); // 希腊等
  }

  static SrcLang? _parseLang(String s) {
    switch (s) {
      case 'zh':
        return SrcLang.zh;
      case 'en':
        return SrcLang.en;
      case 'ru':
        return SrcLang.ru;
      default:
        return null;
    }
  }
}
