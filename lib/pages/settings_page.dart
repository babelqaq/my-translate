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
  late final TextEditingController _modelController;
  late final TextEditingController _modelBaseController;

  @override
  void initState() {
    super.initState();
    final s = context.read<AppSettings>();
    _keyController = TextEditingController(text: s.llmApiKey);
    _modelController = TextEditingController(text: s.llmModel);
    _modelBaseController = TextEditingController(text: s.modelBaseUrl);
  }

  @override
  void dispose() {
    _keyController.dispose();
    _modelController.dispose();
    _modelBaseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    final foreignIsRu = s.foreignLang == 'ru';
    final foreignName = foreignIsRu ? '俄语' : '英文';
    final preset = llmPresets[s.llmProvider]!;
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
          const SizedBox(height: 4),
          TextField(
            controller: _modelBaseController,
            decoration: const InputDecoration(
              labelText: '自定义模型地址（可选）',
              hintText: '留空则自动尝试官方源 / ghproxy 镜像',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            onChanged: (v) => s.setModelBaseUrl(v),
          ),
          const Divider(),
          const Text('翻译后端（国内大模型，免外币信用卡）',
              style: TextStyle(fontWeight: FontWeight.bold)),
          DropdownButtonFormField<String>(
            value: s.llmProvider,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            items: const [
              DropdownMenuItem(value: 'glm', child: Text('智谱 GLM')),
              DropdownMenuItem(value: 'qwen', child: Text('通义千问')),
              DropdownMenuItem(value: 'doubao', child: Text('豆包（火山方舟）')),
            ],
            onChanged: (v) => s.setLlmProvider(v!),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _keyController,
            decoration: const InputDecoration(
              labelText: 'API Key',
              hintText: '粘贴供应商的 API Key',
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            onChanged: (v) => s.setLlmApiKey(v),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _modelController,
            decoration: InputDecoration(
              labelText: '模型（留空用默认）',
              hintText: '默认：${preset.defaultModel}',
              border: const OutlineInputBorder(),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            onChanged: (v) => s.setLlmModel(v),
          ),
          const SizedBox(height: 4),
          Text(
            preset.signupHint,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
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
