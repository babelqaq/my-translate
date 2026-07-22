import 'dart:convert';
import 'package:http/http.dart' as http;

/// 翻译后端：DeepL 免费版（需要免费 API Key）。
///
/// 端点：https://api-free.deepl.com/v2/translate
/// 免费 Key 申请：https://www.deepl.com/pro-api （选 "Free" 套餐，Key 形如 xxxx:fx）
///
/// 支持语种（本项目用到）：EN / ZH / RU。
class TranslationService {
  final String deeplKey;

  TranslationService({required this.deeplKey});

  /// 应用内小写语种代码 -> DeepL 大写代码
  static String _deeplLang(String lang) {
    switch (lang.toLowerCase()) {
      case 'zh':
      case 'zh-cn':
      case 'cn':
        return 'ZH';
      case 'ru':
        return 'RU';
      case 'en':
      default:
        return 'EN';
    }
  }

  Future<String> translate(
    String text, {
    String source = 'en',
    String target = 'zh',
  }) async {
    final q = text.trim();
    if (q.isEmpty) return '';

    if (deeplKey.trim().isEmpty) {
      throw Exception('未配置 DeepL API Key（请在「设置」中填入免费 Key）');
    }

    final uri = Uri.https('api-free.deepl.com', '/v2/translate');
    final resp = await http.post(
      uri,
      headers: {
        'Authorization': 'DeepL-Auth-Key $deeplKey',
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: {
        'text': q,
        'source_lang': _deeplLang(source),
        'target_lang': _deeplLang(target),
      },
    );

    if (resp.statusCode != 200) {
      throw Exception('翻译请求失败（${resp.statusCode}）：${resp.body}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final translations = data['translations'] as List<dynamic>?;
    final translated = (translations != null && translations.isNotEmpty)
        ? (translations.first['text'] as String?)?.trim()
        : null;
    return (translated != null && translated.isNotEmpty) ? translated : q;
  }
}
