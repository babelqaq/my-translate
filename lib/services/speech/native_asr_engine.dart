import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';

/// Kotlin ASR 层上抛的事件（对应 EventChannel "asr/events" 的 JSON）。
class AsrEvent {
  final String type; // ready | status | partial | final | error
  final String text;
  final String? langSwitched; // 仅模式 B 自动兜底切换时携带（Phase D）

  const AsrEvent({
    required this.type,
    this.text = '',
    this.langSwitched,
  });

  @override
  String toString() => 'AsrEvent($type, "$text"${langSwitched != null ? ', lang=$langSwitched' : ''})';
}

/// 封装 Kotlin 原生 ASR 层的 Method/Event Channel。
///
/// 替代旧版 speech_engine.dart / vosk_engine.dart / google_engine.dart 三文件。
/// 无抽象基类——全 App 只有一个引擎（YAGNI）。
class NativeAsrEngine {
  static const _control = MethodChannel('asr/control');
  static const _events = EventChannel('asr/events');

  StreamSubscription? _sub;
  final _controller = StreamController<AsrEvent>.broadcast();

  /// 事件流（broadcast，多个监听者安全）。
  Stream<AsrEvent> get events => _controller.stream;

  /// 开始监听。[mode] = 'zhEn' | 'zhRu'。
  Future<void> start(String mode) async {
    await _control.invokeMethod('start', {'mode': mode});
  }

  /// 停止监听（幂等）。
  Future<void> stop() async {
    await _control.invokeMethod('stop');
  }

  /// 设置活跃语言（仅模式 B 需要；模式 A 单识别器不触发 Kotlin 切换）。
  /// [lang] = 'zh' | 'ru' | 'auto'。
  Future<void> setActiveLang(String lang) async {
    await _control.invokeMethod('setActiveLang', {'lang': lang});
  }

  /// 热更新配置（JSON 字符串，由 Kotlin AsrConfig.fromMap 解析）。
  Future<void> setConfig(Map<String, dynamic> cfg) async {
    await _control.invokeMethod('setConfig', {'config': jsonEncode(cfg)});
  }

  /// 订阅 EventChannel。在 LiveSession.start() 之前调用。
  void subscribe(void Function(AsrEvent) onEvent) {
    _sub?.cancel();
    _sub = _events.receiveBroadcastStream().listen(
      (jsonStr) {
        try {
          final m = jsonDecode(jsonStr as String) as Map<String, dynamic>;
          onEvent(AsrEvent(
            type: m['type'] as String? ?? '',
            text: m['text'] as String? ?? '',
            langSwitched: m['langSwitched'] as String?,
          ));
        } catch (e) {
          // 解析失败不崩，丢弃畸形事件
        }
      },
      onError: (e) {
        onEvent(const AsrEvent(type: 'error', text: 'EventChannel error: $e'));
      },
    );
  }

  /// 取消订阅。在 LiveSession.stop() 之后调用。
  void unsubscribe() {
    _sub?.cancel();
    _sub = null;
  }

  void dispose() {
    _sub?.cancel();
    _controller.close();
  }
}
