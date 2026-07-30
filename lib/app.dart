import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'pages/live_page.dart';
import 'pages/settings_page.dart';
import 'services/app_settings.dart';
import 'services/translation_service.dart';
import 'services/tts_service.dart';
import 'services/live_session.dart';

class MyTranslateApp extends StatelessWidget {
  final AppSettings settings;
  final TranslationService translation;
  final TtsService tts;
  final LiveSession session;

  const MyTranslateApp({
    super.key,
    required this.settings,
    required this.translation,
    required this.tts,
    required this.session,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        Provider.value(value: translation),
        ChangeNotifierProvider.value(value: tts),
        ChangeNotifierProvider.value(value: session),
      ],
      child: MaterialApp(
        title: '语音翻译助手',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          useMaterial3: true,
          brightness: Brightness.light,
        ),
        darkTheme: ThemeData(
          colorSchemeSeed: Colors.indigo,
          useMaterial3: true,
          brightness: Brightness.dark,
        ),
        themeMode: ThemeMode.system,
        home: const LivePage(),
      ),
    );
  }
}
