import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 国内 LLM 翻译供应商预设（OpenAI 兼容接口）。
class LlmPreset {
  final String baseUrl; // 完整的 chat/completions 端点
  final String defaultModel; // 默认模型（免费或有免费额度）
  final String signupHint; // 申请说明

  const LlmPreset(this.baseUrl, this.defaultModel, this.signupHint);
}

const Map<String, LlmPreset> llmPresets = {
  'glm': LlmPreset(
    'https://open.bigmodel.cn/api/paas/v4/chat/completions',
    'glm-4-flash',
    '智谱 AI 开放平台 bigmodel.cn：注册即送额度，glm-4-flash 免费。',
  ),
  'qwen': LlmPreset(
    'https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions',
    'qwen-turbo',
    '阿里云百炼 dashscope.aliyuncs.com：开通模型即送免费额度。',
  ),
  'doubao': LlmPreset(
    'https://ark.cn-beijing.volces.com/api/v3/chat/completions',
    'doubao-seed-1.6-250615',
    '火山方舟 ark.cn-beijing.volces.com：注册送试用额度（模型 ID 在控制台获取）。',
  ),
};

/// 全局设置，使用 shared_preferences 持久化。
///
/// Phase A 字段迁移：
/// - 删除：engine（vosk/google）、modelBaseUrl（不再运行期下载）
/// - 升级：foreignLang('en'/'ru') → mode('zhEn'/'zhRu')，沿用旧 key 做迁移
/// - 新增：streamEnabled（Phase B 用，Phase A 先存）
class AppSettings extends ChangeNotifier {
  static const String _kMode = 'mode';
  static const String _kForeignLangLegacy = 'foreign_lang'; // 旧 key，迁移用
  static const String _kLlmProvider = 'llm_provider';
  static const String _kLlmApiKey = 'llm_api_key';
  static const String _kLlmModel = 'llm_model';
  static const String _kTtsRate = 'tts_rate';
  static const String _kFontSize = 'font_size';
  static const String _kStreamEnabled = 'stream_enabled';

  String _mode = 'zhEn'; // 'zhEn' | 'zhRu'
  String _llmProvider = 'glm'; // 'glm' | 'qwen' | 'doubao'
  String _llmApiKey = '';
  String _llmModel = ''; // 留空则用供应商默认模型
  double _ttsRate = 0.95;
  double _fontSize = 30;
  bool _streamEnabled = true; // Phase B 用

  String get mode => _mode;
  String get llmProvider => _llmProvider;
  String get llmApiKey => _llmApiKey;
  String get llmModel => _llmModel;
  bool get streamEnabled => _streamEnabled;

  /// 当前供应商的完整接口地址
  String get llmBaseUrl => llmPresets[_llmProvider]!.baseUrl;

  /// 实际使用的模型：用户填了用用户的，否则用供应商默认
  String get effectiveModel =>
      _llmModel.trim().isEmpty ? llmPresets[_llmProvider]!.defaultModel : _llmModel.trim();

  double get ttsRate => _ttsRate;
  double get fontSize => _fontSize;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    // 迁移：旧 foreign_lang → 新 mode
    _mode = prefs.getString(_kMode) ?? _migrateForeignLang(prefs);
    _llmProvider = prefs.getString(_kLlmProvider) ?? 'glm';
    _llmApiKey = prefs.getString(_kLlmApiKey) ?? '';
    _llmModel = prefs.getString(_kLlmModel) ?? '';
    _ttsRate = prefs.getDouble(_kTtsRate) ?? 0.95;
    _fontSize = prefs.getDouble(_kFontSize) ?? 30;
    _streamEnabled = prefs.getBool(_kStreamEnabled) ?? true;
    notifyListeners();
  }

  /// 旧版 foreign_lang 迁移到 mode：en → zhEn, ru → zhRu
  String _migrateForeignLang(SharedPreferences prefs) {
    final old = prefs.getString(_kForeignLangLegacy);
    if (old == 'ru') {
      prefs.setString(_kMode, 'zhRu');
      prefs.remove(_kForeignLangLegacy);
      return 'zhRu';
    }
    // en 或 null 都默认 zhEn
    if (old != null) prefs.remove(_kForeignLangLegacy);
    prefs.setString(_kMode, 'zhEn');
    return 'zhEn';
  }

  Future<void> setMode(String v) async {
    _mode = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_kMode, v);
  }

  Future<void> setLlmProvider(String v) async {
    _llmProvider = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_kLlmProvider, v);
  }

  Future<void> setLlmApiKey(String v) async {
    _llmApiKey = v.trim();
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_kLlmApiKey, _llmApiKey);
  }

  Future<void> setLlmModel(String v) async {
    _llmModel = v.trim();
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_kLlmModel, _llmModel);
  }

  Future<void> setTtsRate(double v) async {
    _ttsRate = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setDouble(_kTtsRate, v);
  }

  Future<void> setFontSize(double v) async {
    _fontSize = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setDouble(_kFontSize, v);
  }

  Future<void> setStreamEnabled(bool v) async {
    _streamEnabled = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setBool(_kStreamEnabled, v);
  }
}
