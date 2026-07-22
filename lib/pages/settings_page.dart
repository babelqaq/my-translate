import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_settings.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late final TextEditingController _keyController;

  @override
  void initState() {
    super.initState();
    _keyController = TextEditingController(text: context.read<AppSettings>().deeplKey);
  }

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    final foreignIsRu = s.foreignLang == 'ru';
    final foreignName = foreignIsRu ? '俄语' : '英文';
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('外语（字幕来源 / 同传目标）',
              style: TextStyle(fontWeight: FontWeight.bold)),
          RadioListTile<String>(
            title: const Text('英文'),
            subtitle: const Text('听英文 → 中文字幕；听中文 → 英文同传'),
            value: 'en',
            groupValue: s.foreignLang,
            onChanged: (v) => s.setForeignLang(v!),
          ),
          RadioListTile<String>(
            title: const Text('俄语'),
            subtitle: const Text('听俄语 → 中文字幕；听中文 → 俄语同传'),
            value: 'ru',
            groupValue: s.foreignLang,
            onChanged: (v) => s.setForeignLang(v!),
          ),
          const Divider(),
          const Text('识别引擎', style: TextStyle(fontWeight: FontWeight.bold)),
          RadioListTile<String>(
            title: const Text('Vosk（离线 / 自动检测语种）'),
            subtitle: const Text('免费、无需 Key，首次需下载模型；支持双向自动判别'),
            value: 'vosk',
            groupValue: s.engine,
            onChanged: (v) => s.setEngine(v!),
          ),
          RadioListTile<String>(
            title: const Text('Google（在线 / 更高准确率）'),
            subtitle: const Text('需联网；单语种，仅监听上方选择的外语'),
            value: 'google',
            groupValue: s.engine,
            onChanged: (v) => s.setEngine(v!),
          ),
          if (s.engine == 'google')
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                '提示：Google 引擎为单语种识别，只监听所选外语，'
                '「听中文 → 同传」方向不会触发；如需双向自动判别，请使用 Vosk。',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ),
          const Divider(),
          const Text('DeepL 翻译 Key（免费）',
              style: TextStyle(fontWeight: FontWeight.bold)),
          TextField(
            controller: _keyController,
            decoration: const InputDecoration(
              hintText: '粘贴 DeepL 免费 API Key（形如 xxxxxxxx-xxxx:fx）',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            onChanged: (v) => s.setDeeplKey(v),
          ),
          const SizedBox(height: 4),
          const Text(
            '申请地址：deepl.com/pro-api 选 Free 套餐。免费额度约 50 万字符/月。',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const Divider(),
          const Text('同传语速', style: TextStyle(fontWeight: FontWeight.bold)),
          Slider(
            value: s.ttsRate,
            min: 0.5,
            max: 1.3,
            divisions: 16,
            label: s.ttsRate.toStringAsFixed(2),
            onChanged: (v) => s.setTtsRate(v),
          ),
          const Divider(),
          const Text('字幕字号', style: TextStyle(fontWeight: FontWeight.bold)),
          Slider(
            value: s.fontSize,
            min: 22,
            max: 44,
            divisions: 22,
            label: '${s.fontSize.round()}',
            onChanged: (v) => s.setFontSize(v),
          ),
          const SizedBox(height: 12),
          Text(
            '说明：听$foreignName时，翻译结果以大字幕显示；听中文时，自动朗读$foreignName（同声传译）。',
            style: const TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
