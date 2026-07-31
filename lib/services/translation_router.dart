/// 翻译路由：根据 ASR final 文本和模式，判定源语言与目标语言。
///
/// 这是全 App 语言判定的**唯一**语义实现。
/// Kotlin 侧 charMatch 只是同规则的机械兜底副本（模式 B）。
///
/// 优先级：manualLang（手动 Chip，两种模式均有）> 字符集自动判定。
/// 字符集统计：CJK → zh、西里尔 → ru、拉丁 → en。

enum SrcLang { zh, en, ru }

class RouteResult {
  final SrcLang source;
  final String target; // 'en' | 'ru' | 'zh'

  const RouteResult({required this.source, required this.target});
}

class TranslationRouter {
  /// 字符集"主导"判定比例（与 Kotlin AsrConfig.charDominance 同值）
  static const double _charDominance = 0.6;

  /// 短文本字符数阈值（INV-STICKY-SHORT 用，见 §8.2 第7步）
  static const int _shortTextCharThreshold = 4;

  /// 语种名称（用于翻译 Prompt 填充）
  static const Map<String, String> langNames = {
    'en': 'English',
    'zh': 'Chinese',
    'ru': 'Russian',
  };

  /// 路由：final 文本 + 模式 + 手动语种 + sticky 语种 → 源/目标语言。
  ///
  /// 严格按 §8.2 实现：
  /// 1. 手动优先（INV-MANUAL）；
  /// 2-4. 统计 CJK/拉丁/西里尔，求主导字符集与占比；
  /// 5. 无主导（<0.6）→ null；
  /// 6. 按模式映射（仅本模式有效的字符集生效，其余视为噪声 → null）；
  /// 7. INV-STICKY-SHORT：短文本(<=4)且 mappedLang≠stickyLang → null；
  /// 8. 否则返回 RouteResult。
  ///
  /// 返回 null 表示文本无法判别语言（纯数字/标点/噪声/短文本误判），调用方按 sticky 处理。
  static RouteResult? route(
    String text,
    String mode, {
    String? manualLang,
    String? stickyLang,
  }) {
    // 1. 手动优先（INV-MANUAL）：手动挡直接返回，不进入任何自动判定逻辑
    if (manualLang != null && manualLang != 'auto') {
      final src = _parseLang(manualLang);
      if (src != null) {
        return RouteResult(source: src, target: targetOf(src, mode));
      }
    }

    // 2. 字符集统计（忽略数字/标点/空白/emoji，仅计 CJK/拉丁/西里尔）
    final stats = _scriptCounts(text);
    final totalRelevant = stats.cjk + stats.latin + stats.cyrillic;

    // 3. 完全无法判断（纯数字/纯标点）→ null
    if (totalRelevant == 0) return null;

    // 4. 找主导字符集
    String dominant = 'cjk';
    int maxCount = stats.cjk;
    if (stats.latin > maxCount) {
      maxCount = stats.latin;
      dominant = 'latin';
    }
    if (stats.cyrillic > maxCount) {
      maxCount = stats.cyrillic;
      dominant = 'cyrillic';
    }
    final dominantRatio = maxCount / totalRelevant;

    // 5. 无主导语言（混说）→ null
    if (dominantRatio < _charDominance) return null;

    // 6. 按模式映射（仅本模式有效；其它字符集视为噪声 → null）
    final mappedLang = _scriptToLang(dominant, mode);
    if (mappedLang == null) return null;

    // 7. INV-STICKY-SHORT 短文本保护：
    //    证据不足以推翻 sticky 状态，返回 null 让调用方沿用 stickyLang。
    if (totalRelevant <= _shortTextCharThreshold &&
        stickyLang != null &&
        mappedLang != stickyLang) {
      return null;
    }

    // 8. 否则返回明确判定
    final src = _parseLang(mappedLang)!;
    return RouteResult(source: src, target: targetOf(src, mode));
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

  /// 字符集计数：仅计 CJK / 拉丁 / 西里尔（其它字母/符号不计入 relevant）。
  static ({int cjk, int latin, int cyrillic}) _scriptCounts(String text) {
    int cjk = 0, cyrillic = 0, latin = 0;
    for (final ch in text.runes) {
      if (ch >= 0x4E00 && ch <= 0x9FFF) {
        cjk++;
      } else if (ch >= 0x0400 && ch <= 0x04FF) {
        cyrillic++;
      } else if ((ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A)) {
        latin++;
      }
      // 其它字母/符号不计入 totalRelevant（不影响主导判定）
    }
    return (cjk: cjk, latin: latin, cyrillic: cyrillic);
  }

  /// 字符集 → 语种（按模式）。返回 null 表示该字符集在本模式视为噪声。
  static String? _scriptToLang(String script, String mode) {
    switch (script) {
      case 'cjk':
        return 'zh'; // 两种模式都含中文
      case 'latin':
        return mode == 'zhEn' ? 'en' : null; // 仅模式 A 有效
      case 'cyrillic':
        return mode == 'zhRu' ? 'ru' : null; // 仅模式 B 有效
      default:
        return null;
    }
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
