import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'backup_service.dart';
import 'importer.dart';

/// A request body exceeded the limit imposed by the WiFi server.
class WifiRequestTooLargeException implements Exception {
  final int limit;

  const WifiRequestTooLargeException(this.limit);

  @override
  String toString() => '请求内容超过 ${limit ~/ (1024 * 1024)} MB 限制';
}

/// WiFi 传书：本机启动 HTTP 服务，电脑浏览器上传 txt/epub
class WifiServer {
  WifiServer._({
    InternetAddress? bindAddress,
    Future<List<String>> Function()? ipProvider,
  })  : _bindAddress = bindAddress,
        _ipProvider = ipProvider;
  static final WifiServer instance = WifiServer._();

  /// Creates an isolated server for protocol tests. Production code should
  /// use [instance], which binds to the local network interface.
  factory WifiServer.forTesting({
    InternetAddress? bindAddress,
    Future<List<String>> Function()? ipProvider,
  }) {
    return WifiServer._(
      bindAddress: bindAddress,
      ipProvider: ipProvider,
    );
  }

  /// Maximum size of one uploaded TXT/EPUB file.
  static const int maxUploadBytes = 128 * 1024 * 1024;
  static const int defaultPort = 12345;

  HttpServer? _server;
  int _port = 0;
  String _ip = '';
  final InternetAddress? _bindAddress;
  final Future<List<String>> Function()? _ipProvider;

  bool get running => _server != null;
  int get port => _port;
  String get ip => _ip;
  String get url => 'http://$_ip:$_port';

  /// 文件导入成功的回调（UI 提示）
  void Function(String bookTitle)? onImported;

  Future<List<String>> ipAddresses() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      final ips = <String>[];
      for (final itf in interfaces) {
        for (final addr in itf.addresses) {
          if (!addr.isLoopback && !ips.contains(addr.address)) {
            ips.add(addr.address);
          }
        }
      }
      // 优先局域网地址
      ips.sort((a, b) {
        int score(String s) {
          if (s.startsWith('192.168.') || s.startsWith('10.')) return 0;
          return 1;
        }

        return score(a).compareTo(score(b));
      });
      return ips;
    } catch (_) {
      return const [];
    }
  }

  Future<void> start({int preferredPort = defaultPort}) async {
    if (_server != null) return;
    final ips = await (_ipProvider?.call() ?? ipAddresses());
    if (ips.isEmpty) throw const SocketException('未找到可用的网络地址');
    _ip = ips.first;

    HttpServer? server;
    int port = preferredPort;
    Object? lastError;
    for (int i = 0; i < (preferredPort == 0 ? 1 : 12); i++) {
      try {
        server = await HttpServer.bind(
          _bindAddress ?? InternetAddress.anyIPv4,
          port,
        );
        break;
      } catch (e) {
        lastError = e;
        port++;
      }
    }
    if (server == null) throw lastError ?? '端口绑定失败';
    _port = server.port;
    _server = server;
    server.listen(_handle, onError: (_) {});
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    _port = 0;
    _ip = '';
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      final path = req.uri.path;
      if (req.method == 'GET' && (path == '/' || path == '/index.html')) {
        req.response.headers.contentType = ContentType.html;
        req.response.write(_uploadPage());
        await req.response.close();
        return;
      }
      if (req.method == 'GET' && path == '/backup') {
        final zip = await BackupService.buildBackup();
        req.response.headers.contentType = ContentType('application', 'zip');
        req.response.headers.set(
          'Content-Disposition',
          'attachment; filename="heiyu_backup.zip"',
        );
        req.response.headers.contentLength = zip.length;
        req.response.add(zip);
        await req.response.close();
        return;
      }
      if (req.method == 'POST' && path == '/restore') {
        await _handleRestore(req);
        return;
      }
      if (req.method == 'POST' && path == '/upload') {
        await _handleUpload(req);
        return;
      }
      req.response.statusCode = HttpStatus.notFound;
      await req.response.close();
    } on WifiRequestTooLargeException catch (e) {
      await _tryWriteJson(
        req,
        {'ok': false, 'msg': e.toString()},
        statusCode: HttpStatus.requestEntityTooLarge,
      );
    } catch (_) {
      await _tryWriteJson(
        req,
        {'ok': false, 'msg': '服务器处理失败'},
        statusCode: HttpStatus.internalServerError,
      );
    }
  }

  Future<void> _handleUpload(HttpRequest req) async {
    final name = req.uri.queryParameters['name'] ?? '';
    final lower = name.toLowerCase();
    final supported = lower.endsWith('.txt') || lower.endsWith('.epub');

    if (!supported) {
      await _writeJson(
          req,
          {
            'name': name,
            'ok': false,
            'msg': '仅支持 .txt 和 .epub 文件',
          },
          statusCode: HttpStatus.badRequest);
      return;
    }

    final bytes = await readLimitedBytes(
      req,
      maxBytes: maxUploadBytes,
      contentLength: req.contentLength >= 0 ? req.contentLength : null,
    );
    try {
      final book = await BookImporter.importBytes(name, bytes);
      onImported?.call(book.title);
      await _writeJson(req, {
        'name': name,
        'ok': true,
        'msg': '已加入书架：${book.title}',
      });
    } catch (e) {
      await _writeJson(
          req,
          {
            'name': name,
            'ok': false,
            'msg': '导入失败：$e',
          },
          statusCode: HttpStatus.unprocessableEntity);
    }
  }

  Future<void> _handleRestore(HttpRequest req) async {
    final builder = BytesBuilder(copy: false);
    await req.forEach(builder.add);
    final bytes = builder.takeBytes();
    try {
      final summary = await BackupService.restore(bytes);
      onImported?.call('备份已恢复');
      await _writeJson(req, {'ok': true, 'msg': summary});
    } catch (e) {
      await _writeJson(
          req,
          {
            'ok': false,
            'msg': '恢复失败：$e',
          },
          statusCode: HttpStatus.unprocessableEntity);
    }
  }

  Future<void> _writeJson(
    HttpRequest req,
    Map<String, Object?> body, {
    int statusCode = HttpStatus.ok,
  }) async {
    final response = req.response;
    response.headers.contentType = ContentType.json;
    response.statusCode = statusCode;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    response.write(jsonEncode(body));
    await response.close();
  }

  Future<void> _tryWriteJson(
    HttpRequest req,
    Map<String, Object?> body, {
    required int statusCode,
  }) async {
    try {
      await _writeJson(req, body, statusCode: statusCode);
    } catch (_) {
      // The client may have disconnected while a limited request was being
      // cancelled. There is no response left to send in that case.
    }
  }

  /// Reads a request body incrementally and stops as soon as it exceeds the
  /// supplied limit. [contentLength] is checked before reading any chunk.
  static Future<Uint8List> readLimitedBytes(
    Stream<List<int>> chunks, {
    required int maxBytes,
    int? contentLength,
  }) async {
    if (maxBytes < 0) throw ArgumentError.value(maxBytes, 'maxBytes');
    if (contentLength != null && contentLength > maxBytes) {
      throw WifiRequestTooLargeException(maxBytes);
    }

    final builder = BytesBuilder(copy: false);
    var total = 0;
    await for (final chunk in chunks) {
      total += chunk.length;
      if (total > maxBytes) {
        throw WifiRequestTooLargeException(maxBytes);
      }
      builder.add(chunk);
    }
    return builder.takeBytes();
  }

  String _uploadPage() {
    const uploadLimitMb = maxUploadBytes ~/ (1024 * 1024);
    return '''
<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>黑羽阅读 · WiFi 传书</title>
<style>
:root { color-scheme: dark; }
* { box-sizing: border-box; margin: 0; padding: 0; }
body {
  font-family: -apple-system, "PingFang SC", "Microsoft YaHei", sans-serif;
  background: #0d1015; color: #e6e9ee;
  min-height: 100vh; display: flex; align-items: center; justify-content: center;
}
.wrap { width: min(560px, 92vw); padding: 40px 0; }
.logo { text-align: center; margin-bottom: 28px; }
.logo h1 { font-size: 26px; letter-spacing: 6px; color: #d9a94b; font-weight: 600; }
.logo p { color: #8b93a1; font-size: 13px; margin-top: 8px; letter-spacing: 2px; }
.drop {
  border: 2px dashed #3a4356; border-radius: 16px; padding: 48px 24px;
  text-align: center; cursor: pointer; transition: all .2s;
  background: #131820;
}
.drop.hover { border-color: #d9a94b; background: #1a212c; }
.drop .icon { font-size: 42px; margin-bottom: 12px; }
.drop .main { font-size: 16px; color: #d9a94b; }
.drop .sub { font-size: 13px; color: #8b93a1; margin-top: 8px; }
.backup { display: flex; gap: 12px; margin-top: 18px; justify-content: center; }
.btn {
  padding: 10px 18px; border-radius: 10px; background: #d9a94b;
  color: #241a06; text-decoration: none; font-size: 14px;
  border: none; cursor: pointer; font-family: inherit;
}
.btn.ghost { background: transparent; color: #d9a94b; border: 1px solid #3a4356; }
#file, #restoreFile { display: none; }
.list { margin-top: 20px; }
.item {
  background: #131820; border-radius: 10px; padding: 12px 16px;
  margin-bottom: 10px; display: flex; align-items: center; gap: 12px;
}
.item .name { flex: 1; font-size: 14px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.item .bar { height: 4px; background: #232b38; border-radius: 2px; margin-top: 6px; overflow: hidden; }
.item .bar i { display: block; height: 100%; width: 0; background: #d9a94b; transition: width .15s; }
.item .status { font-size: 12px; color: #8b93a1; white-space: nowrap; }
.item.ok .status { color: #6fce7f; }
.item.err .status { color: #e0655a; }
.tip { margin-top: 24px; text-align: center; color: #57606e; font-size: 12px; line-height: 1.8; }
</style>
</head>
<body>
<div class="wrap">
  <div class="logo">
    <h1>黑羽阅读</h1>
    <p>WIFI 传书 · 拖拽或点击上传</p>
  </div>
  <div class="drop" id="drop">
    <div class="icon">📚</div>
    <div class="main">点击选择文件，或拖拽到此处</div>
    <div class="sub">支持 .txt / .epub，可多选批量上传</div>
  </div>
  <input type="file" id="file" multiple accept=".txt,.epub">
  <div class="backup">
    <a class="btn" href="/backup" download="heiyu_backup.zip">⬇ 下载备份</a>
    <button class="btn ghost" id="restoreBtn" type="button">⬆ 上传备份恢复</button>
    <input type="file" id="restoreFile" accept=".zip">
  </div>
  <div class="list" id="list"></div>
  <div class="tip">单个书籍最大 $uploadLimitMb MB，备份恢复不限大小<br>上传过程中请保持此页面打开<br>文件将自动导入手机书架<br>备份包含书架、书源、阅读点、设置与本地书文件</div>
</div>
<script>
const drop = document.getElementById('drop');
const input = document.getElementById('file');
const list = document.getElementById('list');
drop.addEventListener('click', () => input.click());
drop.addEventListener('dragover', e => { e.preventDefault(); drop.classList.add('hover'); });
drop.addEventListener('dragleave', () => drop.classList.remove('hover'));
drop.addEventListener('drop', e => {
  e.preventDefault(); drop.classList.remove('hover');
  uploadAll(e.dataTransfer.files);
});
input.addEventListener('change', () => { uploadAll(input.files); input.value=''; });

// 备份恢复
const restoreBtn = document.getElementById('restoreBtn');
const restoreFile = document.getElementById('restoreFile');
restoreBtn.addEventListener('click', () => restoreFile.click());
restoreFile.addEventListener('change', async () => {
  const f = restoreFile.files[0];
  restoreFile.value = '';
  if (!f) return;
  restoreBtn.disabled = true;
  restoreBtn.textContent = '恢复中…';
  try {
    const resp = await fetch('/restore', { method: 'POST', body: f });
    const r = await resp.json();
    const row = document.createElement('div');
    row.className = 'item ' + (r.ok ? 'ok' : 'err');
    row.innerHTML = '<div style="flex:1"><div class="name">备份恢复</div></div>' +
      '<div class="status"></div>';
    row.querySelector('.status').textContent = r.msg || (r.ok ? '完成' : '失败');
    list.prepend(row);
  } catch (e) {
    alert('恢复请求失败：' + e);
  }
  restoreBtn.disabled = false;
  restoreBtn.textContent = '⬆ 上传备份恢复';
});

async function uploadAll(files) {
  for (const f of files) { await uploadOne(f); }
}

function uploadOne(file) {
  return new Promise(resolve => {
    const row = document.createElement('div');
    row.className = 'item';
    row.innerHTML = '<div style="flex:1"><div class="name"></div>' +
      '<div class="bar"><i></i></div></div><div class="status">等待中</div>';
    row.querySelector('.name').textContent = file.name;
    list.prepend(row);
    const bar = row.querySelector('.bar i');
    const status = row.querySelector('.status');
    const xhr = new XMLHttpRequest();
    xhr.open('POST', '/upload?name=' + encodeURIComponent(file.name));
    xhr.upload.onprogress = e => {
      if (e.lengthComputable) {
        bar.style.width = Math.round(e.loaded / e.total * 100) + '%';
        status.textContent = Math.round(e.loaded / e.total * 100) + '%';
      }
    };
    xhr.onload = () => {
      try {
        const r = JSON.parse(xhr.responseText);
        status.textContent = r.msg || (r.ok ? '成功' : '失败');
        row.classList.add(r.ok ? 'ok' : 'err');
      } catch (e) {
        status.textContent = '完成';
        row.classList.add('ok');
      }
      resolve();
    };
    xhr.onerror = () => { status.textContent = '网络错误'; row.classList.add('err'); resolve(); };
    xhr.send(file);
  });
}
</script>
</body>
</html>
''';
  }
}
