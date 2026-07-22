import 'package:flutter/material.dart';
import 'app.dart';
import 'services/app_settings.dart';
import 'services/translation_service.dart';
import 'services/tts_service.dart';
import 'services/live_session.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final settings = AppSettings();
  await settings.load();
  final translation = TranslationService(deeplKey: settings.deeplKey);
  final tts = TtsService();
  final session = LiveSession(
    settings: settings,
    translation: translation,
    tts: tts,
  );

  runApp(MyTranslateApp(
    settings: settings,
    translation: translation,
    tts: tts,
    session: session,
  ));
}
