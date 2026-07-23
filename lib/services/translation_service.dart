import 'dart:convert';
import 'package:http/http.dart' as http;
import 'app_settings.dart';

/// 翻译后端：国内大模型（OpenAI 兼容 Chat Completions 接口）。
///
/// 支持任意语种对（本项目用 EN / ZH / RU），无需外币信用卡，
/// 用中国手机号注册即可获得免费额度。可选供应商：
///   - 智谱 GLM（bigmodel.cn，glm-4-flash 免费）
///   - 通义千问（阿里云百炼 dashscope，qwen-turbo 有免费额度）
///   - 豆包（火山方舟 ark）
///
/// 通过 [AppSettings] 实时读取供应商 / Key / 模型，设置页改了立即生效。
class TranslationService {
  final AppSettings settings;

  TranslationService(this.settings);

  /// 语种代码 -> 英文名称（用于构造翻译 prompt）
  static const Map<String, String> _langNames = {
    'en': 'English',
    'zh': 'Chinese',
    'zh-cn': 'Chinese',
    'cn': 'Chinese',
    'ru': 'Russian',
  };

  /// 翻译单段文本。
  /// [source]/[target] 为语种代码（en/zh/ru）。
  /// [isSpeech] 为 true 时按「语音同传」约束：只翻译真实内容、无意义则返回空、
  /// 低温抑制编造，从源头避免没说话也冒出意义不明的同传。
  Future<String> translate(
    String text, {
    String source = 'en',
    String target = 'zh',
    bool isSpeech = true,
    List<String>? context,
  }) async {
    final q = text.trim();
    if (q.isEmpty) return '';

    final apiKey = settings.llmApiKey.trim();
    if (apiKey.isEmpty) {
      throw Exception('未配置翻译 API Key（请在「设置」中选择供应商并填入 Key）');
    }

    final srcName = _langNames[source.toLowerCase()] ?? source;
    final tgtName = _langNames[target.toLowerCase()] ?? target;

    // 语音同传场景：强调只翻译真实内容，禁止对噪声/语气词编造扩展。
    final speechRule = isSpeech
        ? ' The input is transcribed SPEECH and may include filler words '
            '(e.g. "um", "ah", "那个"), disfluencies, or ASR errors. '
            'If the source has no real semantic content — pure filler, a single '
            'pause sound, gibberish, or empty after trimming — respond with an '
            'EMPTY string. Do NOT invent, expand, explain, or add anything '
            'beyond the source. Otherwise correct obvious ASR mistakes and '
            'produce NATURAL, fluent $tgtName.'
        : '';

    // 标点恢复：让译文带自然标点，便于断句与 TTS 停顿更自然。
    final punctRule = isSpeech
        ? ' Restore and include natural punctuation in the translation.'
        : '';

    // 对话上下文：仅用于消歧（指代/术语/语气），不翻译这些历史句。
    final contextRule = (context != null && context.isNotEmpty)
        ? ' The following are recent utterances from the SAME conversation, '
            'provided for CONTEXT ONLY to help you resolve ambiguity, pronouns, '
            'and domain terms — do NOT translate them:\n'
            '${context.map((s) => "- $s").join("\n")}'
        : '';

    final system = 'You are a professional speech interpreter. Translate the '
        "user's text from $srcName to $tgtName.$speechRule$punctRule$contextRule "
        'Output ONLY the translated text, with no quotes, no explanations, and '
        'no extra commentary.';

    final uri = Uri.parse(settings.llmBaseUrl);
    final resp = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': settings.effectiveModel,
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': q},
        ],
        // 翻译/同传需稳定、低创造性：低温抑制幻觉与编造。
        'temperature': 0.1,
        'stream': false,
      }),
    );

    if (resp.statusCode != 200) {
      throw Exception('翻译请求失败（${resp.statusCode}）：${resp.body}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final choices = data['choices'] as List<dynamic>?;
    final content = (choices != null && choices.isNotEmpty)
        ? (choices.first['message']['content'] as String?)?.trim()
        : null;

    // 模型按指示对无意义输入返回空 -> 直接返回空（不显示 / 不朗读）。
    if (content == null || content.isEmpty) return '';

    // 防幻觉后处理：源极短（口语噪声）却被译成明显更长的文本，丢弃。
    if (isSpeech && _looksLikeHallucination(q, content)) return '';

    return content;
  }

  /// 给语音识别原文补全自然标点（不翻译）。
  /// 用于流式断句：Vosk 等 ASR 输出无标点，靠本方法判断「句末」，
  /// 实现「每个句号翻译/同传一次」的流式体验。
  /// 无 API Key 或请求失败时退化返回原文（仍可靠静默兜底整段翻译）。
  Future<String> punctuate(String text, String lang) async {
    final q = text.trim();
    if (q.isEmpty) return '';

    final apiKey = settings.llmApiKey.trim();
    if (apiKey.isEmpty) return q; // 无 Key 退化：不标点，靠兜底

    final langName = _langNames[lang.toLowerCase()] ?? lang;
    final system = 'You are a punctuation restoration assistant for $langName '
        'speech-to-text output. Add natural punctuation (periods, commas, '
        'question marks) where appropriate. Rules: ONLY add punctuation, do NOT '
        'translate, do NOT change, add, or remove any words, and do NOT complete '
        'an unfinished sentence. If the text is clearly a mid-sentence fragment '
        '(cut off, not a complete clause), do NOT put a period at the end. '
        'Output ONLY the punctuated text, with no quotes or commentary.';

    final uri = Uri.parse(settings.llmBaseUrl);
    final resp = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': settings.effectiveModel,
        'messages': [
          {'role': 'system', 'content': system},
          {'role': 'user', 'content': q},
        ],
        'temperature': 0.0,
        'stream': false,
      }),
    );

    if (resp.statusCode != 200) return q; // 失败退化：返回原文
    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final choices = data['choices'] as List<dynamic>?;
    final content = (choices != null && choices.isNotEmpty)
        ? (choices.first['message']['content'] as String?)?.trim()
        : null;
    return content?.isNotEmpty == true ? content! : q;
  }

  /// 源文本很短（≤3 个实义字符）却被译成明显更长的文本，视为模型臆造，丢弃。
  static bool _looksLikeHallucination(String source, String translation) {
    final srcLen = source.replaceAll(RegExp(r'\s+'), '').length;
    final tgtLen = translation.replaceAll(RegExp(r'\s+'), '').length;
    return srcLen <= 3 && tgtLen >= 12;
  }
}
