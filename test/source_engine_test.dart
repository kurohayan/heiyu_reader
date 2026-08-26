import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heiyu_reader/engine/source_engine.dart';
import 'package:heiyu_reader/models/models.dart';

void main() {
  late HttpServer server;
  late BookSource source;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      req.response.headers.contentType =
          ContentType('text', 'html', charset: 'utf-8');
      if (path == '/search') {
        final kw = req.uri.queryParameters['q'] ?? '';
        req.response.write('''
<html><body>
<div class="bookbox">
  <a href="/book/1.html">$kw·斗破苍穹</a>
  <span class="author">天蚕土豆</span>
  <span class="last">更新至第100章</span>
  <img src="/cover/1.jpg">
  <p class="intro">简介A</p>
</div>
</body></html>''');
      } else if (path == '/book/1.html') {
        req.response.write('''
<html><body><ul class="list">
<li><a href="/ch/1.html">第一章 开端</a></li>
<li><a href="/ch/2.html">第二章 发展</a></li>
</ul></body></html>''');
      } else if (path == '/ch/1.html') {
        req.response.write(
            '<html><body><div id="content"><p>第一章内容A</p>'
            '<p>第一章内容B</p></div></body></html>');
      }
      await req.response.close();
    });

    final base = 'http://127.0.0.1:${server.port}';
    source = BookSource(
      name: '测试源',
      url: base,
      json: jsonEncode({
        'bookSourceName': '测试源',
        'bookSourceUrl': base,
        'searchUrl': '$base/search?q={{key}}',
        'ruleSearch': {
          'bookList': 'class.bookbox',
          'name': 'tag.a@text',
          'author': 'class.author@text',
          'lastChapter': 'class.last@text',
          'intro': 'class.intro@text',
          'coverUrl': 'tag.img@src',
          'bookUrl': 'tag.a@href',
        },
        'ruleToc': {
          'chapterList': 'class.list@tag.li',
          'chapterName': 'tag.a@text',
          'chapterUrl': 'tag.a@href',
        },
        'ruleContent': {'content': 'id.content@html'},
      }),
    );
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  test('搜索 → 目录 → 正文 全流程', () async {
    final results = await SourceEngine.search(source, '斗破');
    expect(results.length, 1);
    final r = results.first;
    expect(r.name, contains('斗破苍穹'));
    expect(r.author, '天蚕土豆');
    expect(r.lastChapter, '更新至第100章');
    expect(r.bookUrl, endsWith('/book/1.html'));
    expect(r.coverUrl, contains('/cover/1.jpg'));

    final toc = await SourceEngine.toc(source, r.bookUrl);
    expect(toc.length, 2);
    expect(toc[0].name, '第一章 开端');
    expect(toc[0].url, endsWith('/ch/1.html'));

    final content = await SourceEngine.content(source, toc[0].url);
    expect(content, contains('第一章内容A'));
    expect(content, contains('第一章内容B'));
  });

  test('POST 搜索与订阅 JSON 解析', () async {
    // searchUrl 带选项后缀
    final (url, opts) = _splitHelper(
        'http://x.com/s,{"method":"POST","body":"kw={{key}}"}');
    expect(url, 'http://x.com/s');
    expect(opts['method'], 'POST');

    final sources = SourceEngine.parseSourcesBody(jsonEncode([
      {'bookSourceName': 'A', 'bookSourceUrl': 'http://a.com'},
      {'bookSourceName': 'B', 'bookSourceUrl': 'http://b.com'},
    ]));
    expect(sources.length, 2);

    final single = SourceEngine.parseSourcesBody(
        jsonEncode({'bookSourceName': 'C', 'bookSourceUrl': 'http://c.com'}));
    expect(single.length, 1);
  });

  test('目录规则失效时用常见章节链接兜底', () async {
    final base = 'http://127.0.0.1:${server.port}';
    final fallbackSource = BookSource(
      name: '兜底测试源',
      url: base,
      json: jsonEncode({
        'bookSourceName': '兜底测试源',
        'bookSourceUrl': base,
        'header': jsonEncode({'X-Source-Test': 'yes'}),
        'ruleToc': {
          'chapterList': 'class.changed-layout',
          'chapterName': 'text',
          'chapterUrl': 'href',
        },
        'ruleContent': {'content': 'id.content@html'},
      }),
    );
    final toc = await SourceEngine.toc(fallbackSource, '$base/book/1.html');
    expect(toc.length, 2);
    expect(toc.first.name, '第一章 开端');
  });
}

/// 与引擎内部一致的 searchUrl 拆分（用于验证格式约定）
(String, Map<String, dynamic>) _splitHelper(String raw) {
  final i = raw.indexOf(',{');
  if (i < 0) return (raw, const {});
  final opts = jsonDecode(raw.substring(i + 1));
  return (raw.substring(0, i), opts as Map<String, dynamic>);
}
