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

  @override
  void initState() {
    super.initState();
    final s = context.read<AppSettings>();
    _keyController = TextEditingController(text: s.llmApiKey);
    _modelController = TextEditingController(text: s.llmModel);
  }

  @override
  void dispose() {
    _keyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<AppSettings>();
    final modeName = s.mode == 'zhRu' ? '中文 ⇄ 俄语' : '中文 ⇄ 英语';
    final preset = llmPresets[s.llmProvider]!;
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('当前模式', style: TextStyle(fontWeight: FontWeight.bold)),
          Text(modeName),
          const Text('（在主页面顶部卡片切换）',
              style: TextStyle(fontSize: 12, color: Colors.grey)),
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

          // Phase C 预留：流式翻译开关（Phase A/B 先显示，功能在 Phase C 实现）
          SwitchListTile(
            title: const Text('流式翻译'),
            subtitle: const Text('译文逐字浮现（Phase C 启用，当前为非流式）'),
            value: s.streamEnabled,
            onChanged: (v) => s.setStreamEnabled(v),
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
          const Text(
            '说明：听外语时，翻译结果以大字幕显示（静音）；'
            '听中文时，自动朗读外语（同声传译）。',
            style: TextStyle(fontSize: 13, color: Colors.grey),
          ),
        ],
      ),
    );
  }
}
