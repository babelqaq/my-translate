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

  Future<String> translate(
    String text, {
    String source = 'en',
    String target = 'zh',
  }) async {
    final q = text.trim();
    if (q.isEmpty) return '';

    final apiKey = settings.llmApiKey.trim();
    if (apiKey.isEmpty) {
      throw Exception('未配置翻译 API Key（请在「设置」中选择供应商并填入 Key）');
    }

    final srcName = _langNames[source.toLowerCase()] ?? source;
    final tgtName = _langNames[target.toLowerCase()] ?? target;
    final system =
        'You are a professional translator. Translate the user\'s text from '
        '$srcName to $tgtName. Output ONLY the translated text, with no quotes, '
        'no explanations, and no extra commentary.';

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
        'temperature': 0.3,
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
    return (content != null && content.isNotEmpty) ? content : q;
  }
}
