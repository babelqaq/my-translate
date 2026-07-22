import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:vosk_flutter/vosk_flutter.dart';
import 'speech_engine.dart';

const String _kEnModelUrl =
    'https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip';
const String _kZhModelUrl =
    'https://alphacephei.com/vosk/models/vosk-model-small-cn-0.22.zip';
const String _kRuModelUrl =
    'https://alphacephei.com/vosk/models/vosk-model-small-ru-0.22.zip';

/// 离线识别引擎：同时加载「外语 + 中文」两个 Vosk 小模型，
/// 用一路麦克风 PCM 同时喂给两个识别器，按哪路有有效文本判断语种。
/// 外语可为英文(en)或俄语(ru)，由 [foreignLang] 决定。
class VoskEngine implements SpeechEngine {
  final VoskFlutterPlugin _vosk = VoskFlutterPlugin.instance();
  final ModelLoader _loader = ModelLoader();
  final FlutterSoundRecorder _recorder = FlutterSoundRecorder();

  String _foreignLang = 'en'; // 'en' | 'ru'
  Recognizer? _foreign; // 外语识别器
  Recognizer? _zh; // 中文识别器
  StreamSubscription<Food>? _sub;
  StreamController<Food>? _controller;
  bool _active = false;
  DateTime _lastPartial = DateTime.now();

  @override
  String get name => 'vosk';

  @override
  Future<void> initialize({
    void Function(String status)? onStatus,
    String? foreignLang,
  }) async {
    _foreignLang = foreignLang ?? 'en';
    onStatus?.call('正在加载离线模型（首次运行需联网下载，约 90MB）…');

    final zhPath = await _loader.loadFromNetwork(_kZhModelUrl);
    final foreignPath = _foreignLang == 'ru'
        ? await _loader.loadFromNetwork(_kRuModelUrl)
        : await _loader.loadFromNetwork(_kEnModelUrl);

    _zh = await _vosk.createRecognizer(model: zhPath, sampleRate: 16000);
    _foreign =
        await _vosk.createRecognizer(model: foreignPath, sampleRate: 16000);
  }

  @override
  Future<void> start({
    required void Function(String text, bool isFinal, String lang) onSegment,
    String? localeId,
  }) async {
    if (_foreign == null || _zh == null) {
      throw Exception('Vosk 模型未初始化');
    }
    await _recorder.openRecorder();
    _controller = StreamController<Food>();
    await _recorder.startRecorder(
      toStream: _controller!.sink,
      codec: Codec.pcm16,
      sampleRate: 16000,
      numChannels: 1,
    );
    _active = true;
    _sub = _controller!.stream.listen((food) {
      // flutter_sound 把 PCM 音频包成 FoodData 写入流
      if (food is FoodData) {
        _onAudio(food.data, onSegment);
      }
    });
  }

  Future<void> _onAudio(
    Uint8List chunk,
    void Function(String, bool, String) onSegment,
  ) async {
    if (!_active) return;

    // 以 4096 字节切片（偶数字节，PCM16 要求）同时喂给两个识别器
    for (int i = 0; i < chunk.length; i += 4096) {
      var end = (i + 4096 < chunk.length) ? i + 4096 : chunk.length;
      if (end.isOdd) end--;
      if (end <= i) continue;
      final sub = chunk.sublist(i, end);
      final foreignReady = await _foreign!.acceptWaveformBytes(sub);
      final zhReady = await _zh!.acceptWaveformBytes(sub);
      if (foreignReady) {
        _emit(await _foreign!.getResult(), _foreignLang, true, onSegment);
      }
      if (zhReady) _emit(await _zh!.getResult(), 'zh', true, onSegment);
    }

    // 限流读取 partial 结果，避免过高平台调用频率
    final now = DateTime.now();
    if (now.difference(_lastPartial).inMilliseconds > 140) {
      _lastPartial = now;
      final foreignPartial = _parsePartial(await _foreign!.getPartialResult());
      final zhPartial = _parsePartial(await _zh!.getPartialResult());
      if (zhPartial.trim().isNotEmpty) {
        onSegment(zhPartial, false, 'zh');
      } else if (foreignPartial.trim().isNotEmpty) {
        onSegment(foreignPartial, false, _foreignLang);
      }
    }
  }

  void _emit(
    String json,
    String lang,
    bool isFinal,
    void Function(String, bool, String) onSegment,
  ) {
    final text = _parseText(json);
    if (text.trim().isNotEmpty) onSegment(text, isFinal, lang);
  }

  String _parsePartial(String json) {
    try {
      return (jsonDecode(json)['partial'] as String?) ?? '';
    } catch (_) {
      return '';
    }
  }

  String _parseText(String json) {
    try {
      return (jsonDecode(json)['text'] as String?) ?? '';
    } catch (_) {
      return '';
    }
  }

  @override
  Future<void> stop() async {
    _active = false;
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder.stopRecorder();
    } catch (_) {}
    try {
      await _recorder.closeRecorder();
    } catch (_) {}
    await _controller?.close();
    _controller = null;
  }
}
