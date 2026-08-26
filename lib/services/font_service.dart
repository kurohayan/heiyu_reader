import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../state/app_state.dart';

/// 可下载字体（不进安装包，用户按需下载后运行时加载）
class DownloadableFont {
  final String key;
  final String label;
  final String family; // FontLoader 注册名 / TextStyle 引用名
  final String sizeHint;
  final List<String> urls; // 按顺序回退的下载地址

  const DownloadableFont({
    required this.key,
    required this.label,
    required this.family,
    required this.sizeHint,
    required this.urls,
  });
}

const List<DownloadableFont> kDownloadableFonts = [
  DownloadableFont(
    key: 'wenkai',
    label: '霞鹜文楷 Lite',
    family: 'WenKai',
    sizeHint: '约 13MB',
    urls: [
      'https://github.com/lxgw/LxgwWenKai-Lite/releases/download/v1.522/LXGWWenKaiLite-Regular.ttf',
      'https://mirror.ghproxy.com/https://github.com/lxgw/LxgwWenKai-Lite/releases/download/v1.522/LXGWWenKaiLite-Regular.ttf',
    ],
  ),
  DownloadableFont(
    key: 'noto',
    label: '思源宋体',
    family: 'NotoSerifSC',
    sizeHint: '约 25MB',
    urls: [
      'https://raw.githubusercontent.com/google/fonts/main/ofl/notoserifsc/NotoSerifSC%5Bwght%5D.ttf',
      'https://mirror.ghproxy.com/https://raw.githubusercontent.com/google/fonts/main/ofl/notoserifsc/NotoSerifSC%5Bwght%5D.ttf',
    ],
  ),
];

/// 字体下载/加载服务
class FontService {
  FontService._();

  /// 已在运行时完成加载的字体家族
  static final Set<String> _loaded = {};
  static final Set<String> _downloaded = {};

  static bool isDownloaded(String key) => _downloaded.contains(key);
  static bool isLoaded(String key) => _loaded.contains(key);

  static DownloadableFont? byKey(String key) {
    for (final f in kDownloadableFonts) {
      if (f.key == key) return f;
    }
    return null;
  }

  static Future<Directory> _fontsDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(docs.path, 'fonts'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<File> _fileOf(DownloadableFont font) async {
    final dir = await _fontsDir();
    return File(p.join(dir.path, '${font.key}.ttf'));
  }

  /// 启动时：扫描已下载字体，并加载当前选中项
  static Future<void> init() async {
    for (final font in kDownloadableFonts) {
      final f = await _fileOf(font);
      if (await f.exists() && await f.length() > 100000) {
        _downloaded.add(font.key);
      }
    }
    final key = ReaderSettings.fontKey;
    if (_downloaded.contains(key)) {
      await load(key);
    }
  }

  /// 用 FontLoader 在运行时注册字体家族
  static Future<bool> load(String key) async {
    if (_loaded.contains(key)) return true;
    final font = byKey(key);
    if (font == null) return false;
    try {
      final f = await _fileOf(font);
      if (!await f.exists()) return false;
      final bytes = await f.readAsBytes();
      final loader = FontLoader(font.family)
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      _loaded.add(key);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 下载字体（带进度回调 0.0~1.0），成功后立即可用
  static Future<void> download(
    String key, {
    void Function(double progress)? onProgress,
  }) async {
    final font = byKey(key);
    if (font == null) throw '未知字体';
    Object? lastError;
    for (final url in font.urls) {
      try {
        final client = http.Client();
        try {
          final request = http.Request('GET', Uri.parse(url));
          final response = await client
              .send(request)
              .timeout(const Duration(seconds: 30));
          if (response.statusCode != 200) {
            throw 'HTTP ${response.statusCode}';
          }
          final total = response.contentLength ?? 0;
          final builder = BytesBuilder(copy: false);
          var received = 0;
          await for (final chunk in response.stream.timeout(
            const Duration(seconds: 60),
          )) {
            builder.add(chunk);
            received += chunk.length;
            if (total > 0) onProgress?.call(received / total);
          }
          final bytes = builder.takeBytes();
          if (bytes.length < 100000) throw '文件不完整';
          final f = await _fileOf(font);
          await f.writeAsBytes(bytes, flush: true);
          _downloaded.add(key);
          onProgress?.call(1);
          await load(key);
          return;
        } finally {
          client.close();
        }
      } catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? '下载失败';
  }

  /// 删除已下载字体；若当前正在使用则回退默认字体
  static Future<void> remove(String key) async {
    final font = byKey(key);
    if (font == null) return;
    final f = await _fileOf(font);
    if (await f.exists()) await f.delete();
    _downloaded.remove(key);
    _loaded.remove(key);
    if (ReaderSettings.fontKey == key) {
      ReaderSettings.fontKey = 'system';
      await ReaderSettings.save();
    }
  }
}
