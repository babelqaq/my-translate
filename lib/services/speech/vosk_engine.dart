import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_sound/flutter_sound.dart';
import 'package:vosk_flutter/vosk_flutter.dart';
import 'speech_engine.dart';

/// 你的 GitHub 仓库（用于经 ghproxy 镜像下载模型，需与实际情况一致）。
const String _kRepoSlug = 'babelqaq/my-translate';
const String _kEnFile = 'vosk-model-small-en-us-0.15.zip';
const String _kZhFile = 'vosk-model-small-cn-0.22.zip';
const String _kRuFile = 'vosk-model-small-ru-0.22.zip';

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

  /// 自定义模型下载基址（可选）。在「设置」填写，用于国内不可达官方源时
  /// 指向自己的对象存储 / 国内可达镜像。留空则自动多源重试。
  String? _modelBaseUrl;

  set modelBaseUrl(String? v) =>
      _modelBaseUrl = (v == null || v.trim().isEmpty) ? null : v.trim();

  @override
  String get name => 'vosk';

  @override
  Future<void> initialize({
    void Function(String status)? onStatus,
    String? foreignLang,
  }) async {
    _foreignLang = foreignLang ?? 'en';
    onStatus?.call('正在准备离线模型（优先从安装包加载，首次需解压）…');
    try {
      // 多源重试：自定义地址 → 多个 ghproxy 镜像 → 官方源（国内常不可达）
      final zhPath = await _loadModel(_kZhFile, onStatus: onStatus);
      final foreignFile = _foreignLang == 'ru' ? _kRuFile : _kEnFile;
      final foreignPath = await _loadModel(foreignFile, onStatus: onStatus);

      // 必须先 createModel(path) 得到 Model 对象，再传给 createRecognizer
      final zhModel = await _vosk.createModel(zhPath);
      final foreignModel = await _vosk.createModel(foreignPath);

      _zh = await _vosk.createRecognizer(model: zhModel, sampleRate: 16000);
      _foreign =
          await _vosk.createRecognizer(model: foreignModel, sampleRate: 16000);
    } catch (e) {
      throw Exception('离线模型加载失败：$e');
    }
  }

  /// 按优先级拼接候选下载地址（自定义基址 + 多个镜像 + 官方源）。
  List<String> _candidateUrls(String file) {
    final urls = <String>[];
    if (_modelBaseUrl != null) {
      final base = _modelBaseUrl!.endsWith('/')
          ? _modelBaseUrl!.substring(0, _modelBaseUrl!.length - 1)
          : _modelBaseUrl!;
      urls.add('$base/$file');
    }
    const mirrors = [
      'https://ghproxy.com',
      'https://ghproxy.net',
      'https://mirror.ghproxy.com',
      'https://ghproxy.cfd',
    ];
    for (final m in mirrors) {
      urls.add(
          '$m/https://github.com/$_kRepoSlug/releases/download/models/$file');
    }
    urls.add('https://alphacephei.com/vosk/models/$file');
    return urls;
  }

  /// 加载单个模型，优先级：
  /// 1) 从 APK 内置 assets 读取（已把模型 zip 放进 assets/models/ 时完全离线）
  /// 2) 多源联网下载（自定义地址 → ghproxy 镜像 → 官方源）兜底
  /// 全部失败则抛出明确错误，提示用户在设置填写自定义地址。
  Future<String> _loadModel(
    String file, {
    required void Function(String)? onStatus,
  }) async {
    // 1) 优先从安装包内置 assets 加载（捆绑模型后手机端零联网）
    try {
      onStatus?.call('正在从安装包加载内置模型：$file');
      final path = await _loader.loadFromAssets('assets/models/$file');
      if (path.trim().isNotEmpty) return path;
    } catch (e, st) {
      // 内置 assets 没有该模型（未捆绑 / 装的是不含模型的旧包），回退到联网下载。
      // 打印真实异常便于排查：最常见是 "Unable to load asset"（APK 未打包该 zip）。
      print('[vosk] 内置模型加载失败，将回退联网下载：$file\n$e');
      print(st);
    }

    // 2) 多源联网下载兜底
    final candidates = _candidateUrls(file);
    for (final url in candidates) {
      try {
        onStatus?.call('正在下载模型：$file\n来源：$url');
        final path = await _loader.loadFromNetwork(url);
        if (path.trim().isNotEmpty) return path;
      } catch (_) {
        // 该源失败，尝试下一个
      }
    }
    throw Exception(
        '所有模型来源均失败。请确认已将模型 zip 放入 assets/models/ 后重新构建，'
        '或在「设置」填写自定义模型地址（国内可访问的镜像或对象存储），'
        '或科学上网后重试。');
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
      // flutter_sound 中 Food 是 sealed 抽象类，.data 仅在子类 FoodData 上，
      // 且类型为可空 Uint8List?；需先 is FoodData 判定，再做 null 判空。
      if (food is FoodData) {
        final data = food.data;
        if (data != null && data.isNotEmpty) {
          _onAudio(data, onSegment);
        }
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
