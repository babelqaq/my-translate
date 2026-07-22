import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局设置，使用 shared_preferences 持久化。
class AppSettings extends ChangeNotifier {
  static const String _kEngine = 'engine';
  static const String _kForeignLang = 'foreign_lang';
  static const String _kDeeplKey = 'deepl_key';
  static const String _kTtsRate = 'tts_rate';
  static const String _kFontSize = 'font_size';

  String _engine = 'vosk'; // 'vosk' | 'google'
  String _foreignLang = 'en'; // 'en' | 'ru'（外语：字幕来源 / 同传目标）
  String _deeplKey = ''; // DeepL 免费 API Key
  double _ttsRate = 0.95;
  double _fontSize = 30;

  String get engine => _engine;
  String get foreignLang => _foreignLang;
  String get deeplKey => _deeplKey;
  double get ttsRate => _ttsRate;
  double get fontSize => _fontSize;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _engine = prefs.getString(_kEngine) ?? 'vosk';
    _foreignLang = prefs.getString(_kForeignLang) ?? 'en';
    _deeplKey = prefs.getString(_kDeeplKey) ?? '';
    _ttsRate = prefs.getDouble(_kTtsRate) ?? 0.95;
    _fontSize = prefs.getDouble(_kFontSize) ?? 30;
    notifyListeners();
  }

  Future<void> setEngine(String v) async {
    _engine = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_kEngine, v);
  }

  Future<void> setForeignLang(String v) async {
    _foreignLang = v;
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_kForeignLang, v);
  }

  Future<void> setDeeplKey(String v) async {
    _deeplKey = v.trim();
    notifyListeners();
    (await SharedPreferences.getInstance()).setString(_kDeeplKey, _deeplKey);
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
}
