import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/live_session.dart';
import '../services/app_settings.dart';
import 'settings_page.dart';

class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  final ScrollController _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<LiveSession>();
    final settings = context.watch<AppSettings>();
    final fontSize = settings.fontSize;
    final listening = session.status == 'listening';

    // 有新字幕时自动滚到底部
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());

    final langLabel = session.partialLang == 'zh'
        ? '中文'
        : session.partialLang == 'en'
            ? '英文'
            : session.partialLang == 'ru'
                ? '俄语'
                : '自动识别';
    final foreignName = settings.foreignLang == 'ru' ? '俄语' : '英文';

    return Scaffold(
      appBar: AppBar(
        title: const Text('语音翻译助手'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: '设置',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsPage()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空字幕',
            onPressed: session.notes.isEmpty ? null : () => session.clearNotes(),
          ),
        ],
      ),
      body: Column(
        children: [
          // 状态条
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: listening
                ? Theme.of(context).colorScheme.primaryContainer
                : Theme.of(context).colorScheme.surfaceVariant,
            child: Row(
              children: [
                Icon(listening ? Icons.graphic_eq : Icons.mic_off, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    session.status == 'error'
                        ? session.statusText
                        : (listening ? '监听中 · $langLabel' : session.statusText),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                if (session.partialLang == 'zh')
                  const Text('🔊', style: TextStyle(fontSize: 16))
                else if (session.partialLang == 'en' || session.partialLang == 'ru')
                  const Text('📝', style: TextStyle(fontSize: 16)),
              ],
            ),
          ),

          // 实时识别（小字灰）
          if (session.partial.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                session.partial,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.outline,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),

          // 同传反馈（小字）
          if (session.message.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: Text(
                session.message,
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.primary,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),

          // 字幕笔记列表
          Expanded(
            child: session.notes.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        '点击下方按钮开始\n听$foreignName → 中文滚动字幕\n听中文 → $foreignName同声传译',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          color: Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    controller: _scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: session.notes.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (_, i) {
                      final n = session.notes[i];
                      return Card(
                        elevation: 1,
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                n.source,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: Theme.of(context).colorScheme.outline,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                n.translation,
                                style: TextStyle(
                                  fontSize: fontSize,
                                  fontWeight: FontWeight.w600,
                                  height: 1.3,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),

          // 开始 / 停止按钮
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: SizedBox(
              width: double.infinity,
              height: 56,
              child: FilledButton.icon(
                onPressed: session.status == 'loading'
                    ? null
                    : () {
                        if (listening) {
                          session.stop();
                        } else {
                          session.start();
                        }
                      },
                icon: Icon(listening ? Icons.stop : Icons.mic),
                label: Text(
                  session.status == 'loading'
                      ? '准备中…'
                      : listening
                          ? '停止'
                          : '开始',
                  style: const TextStyle(fontSize: 18),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: listening
                      ? Colors.redAccent
                      : Theme.of(context).colorScheme.primary,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
