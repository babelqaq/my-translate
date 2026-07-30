import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/live_session.dart';
import '../services/app_settings.dart';
import 'settings_page.dart';

/// 状态条渲染所需的最小快照。status / statusText 两者的最小集合。
@immutable
class _StatusView {
  final SessionStatus status;
  final String statusText;
  const _StatusView(this.status, this.statusText);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _StatusView &&
          other.status == status &&
          other.statusText == statusText;

  @override
  int get hashCode => status.hashCode ^ statusText.hashCode;
}

class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  final ScrollController _scroll = ScrollController();
  int _lastNotesCount = 0;

  @override
  void initState() {
    super.initState();
    final session = context.read<LiveSession>();
    _lastNotesCount = session.notes.length;
    session.addListener(_onSessionChanged);
  }

  @override
  void dispose() {
    context.read<LiveSession>().removeListener(_onSessionChanged);
    _scroll.dispose();
    super.dispose();
  }

  void _onSessionChanged() {
    final count = context.read<LiveSession>().notes.length;
    if (count != _lastNotesCount) {
      _lastNotesCount = count;
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
    }
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
          Selector<LiveSession, bool>(
            selector: (_, s) => s.notes.isEmpty,
            builder: (context, notesEmpty, _) => IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '清空字幕',
              onPressed: notesEmpty
                  ? null
                  : () => context.read<LiveSession>().clearNotes(),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          // ---------- 模式卡片 ----------
          Selector<AppSettings, String>(
            selector: (_, s) => s.mode,
            builder: (context, mode, _) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: _ModeCard(
                        label: '中 ⇄ 英',
                        selected: mode == 'zhEn',
                        onTap: () =>
                            context.read<LiveSession>().setMode('zhEn'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ModeCard(
                        label: '中 ⇄ 俄',
                        selected: mode == 'zhRu',
                        onTap: () =>
                            context.read<LiveSession>().setMode('zhRu'),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          // ---------- 状态条 ----------
          Selector<LiveSession, _StatusView>(
            selector: (_, s) => _StatusView(s.status, s.statusText),
            builder: (context, view, _) {
              final listening = view.status == SessionStatus.listening;
              return Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                color: listening
                    ? Theme.of(context).colorScheme.primaryContainer
                    : Theme.of(context).colorScheme.surfaceVariant,
                child: Row(
                  children: [
                    Icon(listening ? Icons.graphic_eq : Icons.mic_off, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        view.status == SessionStatus.error
                            ? view.statusText
                            : (listening
                                ? '监听中'
                                : view.statusText),
                        style: const TextStyle(fontSize: 14),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          // ---------- "正在听"预览 ----------
          Selector<LiveSession, String>(
            selector: (_, s) => s.partial,
            builder: (context, partial, _) => partial.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: Text(
                      '正在听: $partial',
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.outline,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
          ),

          // ---------- 同传反馈 ----------
          Selector<LiveSession, String>(
            selector: (_, s) => s.message,
            builder: (context, message, _) => message.isEmpty
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                    child: Text(
                      message,
                      style: TextStyle(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
          ),

          // ---------- 字幕列表 ----------
          Expanded(
            child: Selector<LiveSession, List<NoteEntry>>(
              selector: (_, s) => s.notes,
              builder: (context, notes, _) {
                final settings = context.watch<AppSettings>();
                final fontSize = settings.fontSize;
                return notes.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            '点击下方按钮开始\n'
                            '听外语 → 中文滚动字幕\n'
                            '听中文 → 外语同声传译',
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
                        itemCount: notes.length,
                        separatorBuilder: (_, __) =>
                            const SizedBox(height: 12),
                        itemBuilder: (_, i) {
                          final n = notes[i];
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
                                      color: Theme.of(context)
                                          .colorScheme
                                          .outline,
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
                      );
              },
            ),
          ),

          // ---------- 手动语种 Chip（两种模式均显示） ----------
          Selector<LiveSession, String>(
            selector: (_, s) => s.manualLang,
            builder: (context, manualLang, _) {
              final mode = context.watch<AppSettings>().mode;
              final foreignCode = mode == 'zhRu' ? 'ru' : 'en';
              final foreignName = mode == 'zhRu' ? '俄语' : '英文';
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: Row(
                  children: [
                    const Text('输入语种', style: TextStyle(fontSize: 13)),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('自动'),
                      selected: manualLang == 'auto',
                      onSelected: (_) =>
                          context.read<LiveSession>().setManualLang('auto'),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: const Text('中文'),
                      selected: manualLang == 'zh',
                      onSelected: (_) =>
                          context.read<LiveSession>().setManualLang('zh'),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(foreignName),
                      selected: manualLang == foreignCode,
                      onSelected: (_) => context
                          .read<LiveSession>()
                          .setManualLang(foreignCode),
                    ),
                  ],
                ),
              );
            },
          ),

          // ---------- 开始 / 停止 ----------
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Selector<LiveSession, SessionStatus>(
              selector: (_, s) => s.status,
              builder: (context, status, _) {
                final loading = status == SessionStatus.loading;
                final listening = status == SessionStatus.listening;
                return SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: FilledButton.icon(
                    onPressed: loading
                        ? null
                        : () {
                            final session = context.read<LiveSession>();
                            if (listening) {
                              session.stop();
                            } else {
                              session.start();
                            }
                          },
                    icon: Icon(listening ? Icons.stop : Icons.mic),
                    label: Text(
                      loading
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
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 模式卡片
class _ModeCard extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeCard({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? Theme.of(context).colorScheme.primaryContainer
              : Theme.of(context).colorScheme.surfaceVariant,
          borderRadius: BorderRadius.circular(12),
          border: selected
              ? Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 2,
                )
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: selected
                ? Theme.of(context).colorScheme.primary
                : Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
