import 'package:flutter_tts/flutter_tts.dart';

/// 听书 TTS 服务（iOS 用系统 AVSpeechSynthesizer）
class TtsService {
  TtsService._();
  static final TtsService instance = TtsService._();

  final FlutterTts _tts = FlutterTts();
  bool _inited = false;
  double rate = 0.5;
  String? _voiceKey;

  Future<void> _init() async {
    if (_inited) return;
    try {
      await _tts.setLanguage('zh-CN');
      await _tts.setSpeechRate(rate);
      await _tts.setVolume(1.0);
      await _tts.awaitSpeakCompletion(true);
      if (_voiceKey != null) await _applyVoice(_voiceKey!);
      _inited = true;
    } catch (_) {}
  }

  Future<void> _applyVoice(String key) async {
    final parts = key.split('|');
    if (parts.length == 2) {
      await _tts.setVoice({'name': parts[0], 'locale': parts[1]});
    }
  }

  /// 系统可用音色列表（中文优先）
  Future<List<Map<String, String>>> voices() async {
    await _init();
    final list = <Map<String, String>>[];
    try {
      final raw = await _tts.getVoices;
      if (raw is List) {
        for (final item in raw) {
          if (item is Map) {
            final m = {
              for (final e in item.entries) '${e.key}': '${e.value}',
            };
            list.add(m);
          }
        }
      }
    } catch (_) {}
    list.sort((a, b) {
      bool zh(Map<String, String> v) =>
          (v['locale'] ?? '').toLowerCase().startsWith('zh');
      if (zh(a) && !zh(b)) return -1;
      if (!zh(a) && zh(b)) return 1;
      return (a['name'] ?? '').compareTo(b['name'] ?? '');
    });
    return list;
  }

  String? get voiceKey => _voiceKey;

  Future<void> setVoice(String key) async {
    _voiceKey = key;
    if (_inited) {
      try {
        await _applyVoice(key);
      } catch (_) {}
    }
  }

  Future<void> setRate(double r) async {
    rate = r;
    if (_inited) {
      try {
        await _tts.setSpeechRate(r);
      } catch (_) {}
    }
  }

  /// 依次朗读分段；isCancelled 返回 true 时中断
  Future<void> speakChunks(
    List<String> chunks, {
    required bool Function() isCancelled,
    void Function(int index)? onChunk,
  }) async {
    await _init();
    for (int i = 0; i < chunks.length; i++) {
      if (isCancelled()) break;
      onChunk?.call(i);
      try {
        await _tts.speak(chunks[i]);
      } catch (_) {
        break;
      }
    }
  }

  Future<void> stop() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}
