import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'app_settings.dart';

/// 翻译后端：国内大模型（OpenAI 兼容 Chat Completions 接口）。
///
/// Phase A/B：非流式翻译（Phase C 将新增 translateStream SSE）。
/// Phase A 已删除 punctuate()——标点由翻译 Prompt 一并处理（S2/S6 消亡）。
class TranslationService {
  final AppSettings settings;
  final http.Client _client = http.Client();

  /// 单次 LLM 请求超时：实时翻译场景，弱网下不应无限等待。
  static const Duration _kRequestTimeout = Duration(seconds: 10);

  TranslationService(this.settings);

  void dispose() => _client.close();

  /// 语种代码 -> 英文名称（用于构造翻译 prompt）
  static const Map<String, String> _langNames = {
    'en': 'English',
    'zh': 'Chinese',
    'zh-cn': 'Chinese',
    'cn': 'Chinese',
    'ru': 'Russian',
  };

  /// 统一的 LLM 请求封装：构造 messages、发送、解析 content。
  ///
  /// - 成功返回模型原文（已 trim）；
  /// - 超时 / 网络异常 / 非 200 时降级返回 [onFail]（默认 null）。
  Future<String?> _chat(
    String system,
    String user, {
    double temperature = 0.1,
    String? onFail,
  }) async {
    final apiKey = settings.llmApiKey.trim();
    final uri = Uri.parse(settings.llmBaseUrl);
    try {
      final resp = await _client
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode({
              'model': settings.effectiveModel,
              'messages': [
                {'role': 'system', 'content': system},
                {'role': 'user', 'content': user},
              ],
              'temperature': temperature,
              'stream': false,
            }),
          )
          .timeout(_kRequestTimeout);
      if (resp.statusCode != 200) {
        debugPrint('[translate] 请求失败（${resp.statusCode}）：${resp.body}');
        return onFail;
      }
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final choices = data['choices'] as List<dynamic>?;
      final content = (choices != null && choices.isNotEmpty)
          ? (choices.first['message']['content'] as String?)?.trim()
          : null;
      return content;
    } on TimeoutException {
      debugPrint('[translate] 请求超时（>$_kRequestTimeout）');
      return onFail;
    } catch (e) {
      debugPrint('[translate] 请求异常：$e');
      return onFail;
    }
  }

  /// 翻译单段文本。
  ///
  /// [source] 源语言代码：'en' | 'zh' | 'ru'
  /// [target] 目标语言代码：'en' | 'zh' | 'ru'
  /// [text]   待翻译文本
  ///
  /// 失败（超时/异常/非 200）抛 Exception，由调用方显示「翻译失败」。
  Future<String> translate(String source, String target, String text) async {
    final q = text.trim();
    if (q.isEmpty) return '';

    final apiKey = settings.llmApiKey.trim();
    if (apiKey.isEmpty) {
      throw Exception('未配置翻译 API Key（请在「设置」中选择供应商并填入 Key）');
    }

    final srcName = _langNames[source.toLowerCase()] ?? source;
    final tgtName = _langNames[target.toLowerCase()] ?? target;

    // 语音同传场景：强调只翻译真实内容，禁止对噪声/语气词编造扩展。
    final system = 'You are a professional speech interpreter. Translate the '
        "user's text from $srcName to $tgtName. "
        'The input is transcribed SPEECH and may include filler words '
        '(e.g. "um", "ah", "那个"), disfluencies, or ASR recognition errors '
        'such as homophone confusion (e.g. "sun" vs "sound") and unintended '
        'repetition from slips of the tongue. '
        'If the source has no real semantic content — pure filler, a single '
        'pause sound, gibberish, or empty after trimming — respond with an '
        'EMPTY string. Do NOT invent, expand, explain, or add anything '
        'beyond the source. Otherwise correct obvious ASR mistakes: using the '
        'surrounding context, infer the speaker\u2019s true intent and do NOT '
        'translate a clear recognition error literally word-for-word. Produce '
        'NATURAL, fluent $tgtName with natural punctuation. '
        'Output ONLY the translated text, with no quotes, no explanations, and '
        'no extra commentary.';

    final content = await _chat(system, q, temperature: 0.1);
    if (content == null) {
      throw Exception('翻译请求失败（网络超时或服务异常）');
    }
    if (content.isEmpty) return '';

    // 防幻觉后处理：源极短（口语噪声）却被译成明显更长的文本，丢弃。
    if (_looksLikeHallucination(q, content)) return '';

    return content;
  }

  /// 源文本很短（≤3 个实义字符）却被译成明显更长的文本，视为模型臆造，丢弃。
  static bool _looksLikeHallucination(String source, String translation) {
    final srcLen = source.replaceAll(RegExp(r'\s+'), '').length;
    final tgtLen = translation.replaceAll(RegExp(r'\s+'), '').length;
    return srcLen <= 3 && tgtLen >= 12;
  }
}
