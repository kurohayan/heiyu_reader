import 'dart:convert';
import 'dart:io';

import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;

import '../models/models.dart';
import '../utils/html_text.dart';
import '../utils/text_encoding.dart';
import 'selector.dart';

/// 书源抓取引擎：搜索、目录、正文。
class SourceEngine {
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
  static const Duration _timeout = Duration(seconds: 20);

  static Future<String> fetch(
    String url, {
    String method = 'GET',
    String? body,
    Map<String, String>? extraHeaders,
  }) async {
    final uri = Uri.parse(url.trim());
    final headers = <String, String>{
      'User-Agent': _ua,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
    };
    extraHeaders?.forEach((key, value) => headers[key] = value);

    final http.Response response;
    if (method.toUpperCase() == 'POST') {
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
      response = await http
          .post(uri, headers: headers, body: body ?? '')
          .timeout(_timeout);
    } else {
      response = await http.get(uri, headers: headers).timeout(_timeout);
    }
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode}');
    }
    return decodeHtmlBytes(response.bodyBytes, response.headers['content-type']);
  }

  static (String, Map<String, dynamic>) _splitUrl(String raw) {
    final i = raw.indexOf(',{');
    if (i < 0) return (raw.trim(), const {});
    try {
      final options = jsonDecode(raw.substring(i + 1));
      if (options is Map<String, dynamic>) {
        return (raw.substring(0, i).trim(), options);
      }
    } catch (_) {}
    return (raw.trim(), const {});
  }

  static String _fill(
    String template,
    String key,
    int page, {
    bool gbkKey = false,
  }) {
    final encoded =
        gbkKey ? gbkQueryComponent(key) : Uri.encodeQueryComponent(key);
    final upper = gbkKey
        ? gbkQueryComponent(key.toUpperCase())
        : Uri.encodeQueryComponent(key.toUpperCase());
    return template
        .replaceAll('{{key}}', encoded)
        .replaceAll('{{KEY}}', upper)
        .replaceAll('{{Key}}', encoded)
        .replaceAll('{{page}}', '$page')
        .replaceAll('{{Page}}', '$page');
  }

  static Map<String, String> _sourceHeaders(Map<String, dynamic> rule) {
    final header = rule['header'];
    if (header is String && header.trim().startsWith('{')) {
      try {
        final decoded = jsonDecode(header);
        if (decoded is Map) {
          return {
            for (final entry in decoded.entries)
              if (entry.key is String) entry.key as String: '${entry.value}',
          };
        }
      } catch (_) {}
    }
    return const {};
  }

  static List<Map<String, dynamic>> parseSourcesBody(String body) {
    final data = jsonDecode(body.trim());
    if (data is List) {
      return [for (final item in data) if (item is Map<String, dynamic>) item];
    }
    if (data is Map<String, dynamic>) {
      final inner = data['bookSources'];
      if (inner is List) {
        return [for (final item in inner) if (item is Map<String, dynamic>) item];
      }
      if (data.containsKey('bookSourceUrl')) return [data];
    }
    return const [];
  }

  static Future<List<SearchResultItem>> search(
    BookSource source,
    String keyword, {
    int page = 1,
  }) async {
    final rule = jsonDecode(source.json) as Map<String, dynamic>;
    final rawSearchUrl = (rule['searchUrl'] as String?) ?? '';
    if (rawSearchUrl.trim().isEmpty) return const [];

    final (urlTemplate, options) = _splitUrl(rawSearchUrl);
    final method = ((options['method'] as String?) ?? 'GET').toUpperCase();
    final bodyTemplate = options['body'] as String?;
    final hasKeyword = _hasKeywordPlaceholder(urlTemplate) ||
        (bodyTemplate != null && _hasKeywordPlaceholder(bodyTemplate));
    // 不支持 legado 的 JS 搜索，也不把没有关键词的首页误当搜索结果。
    if (urlTemplate.trim().startsWith('@js:') || !hasKeyword) {
      return const [];
    }
    final gbkKey = urlTemplate.toLowerCase().contains('gbk') ||
        ((options['charset'] as String?)?.toLowerCase().contains('gbk') ?? false);
    final url = _fill(urlTemplate, keyword, page, gbkKey: gbkKey);
    final body = bodyTemplate == null
        ? null
        : _fill(bodyTemplate, keyword, page, gbkKey: gbkKey);
    final html = await fetch(
      url,
      method: method,
      body: body,
      extraHeaders: _sourceHeaders(rule),
    );
    final document = html_parser.parse(html);

    final rawRule = rule['ruleSearch'];
    final searchRule = rawRule is Map<String, dynamic>
        ? rawRule
        : <String, dynamic>{};
    final listRule = (searchRule['bookList'] as String?) ?? '';
    if (listRule.isEmpty) return const [];

    final base = (rule['bookSourceUrl'] as String?) ?? source.url;
    final items = RuleSelector.elements(document, listRule);
    final results = <SearchResultItem>[];
    for (final element in items) {
      String field(String key) =>
          _evalField(element, (searchRule[key] as String?) ?? '');

      final name = field('name');
      var bookUrl = field('bookUrl');
      if (name.isEmpty) continue;
      if (bookUrl.isEmpty) bookUrl = (element.attributes['href'] ?? '').trim();
      if (bookUrl.isEmpty) continue;

      var cover = field('coverUrl');
      if (cover.isNotEmpty) cover = _abs(base, cover);
      final author = field('author');
      final intro = field('intro');
      final lastChapter = field('lastChapter');
      // 搜索结果相关性过滤：防止把站点首页推荐书误认成关键词结果。
      if (!_matchesKeyword(keyword, name, author, intro, lastChapter)) {
        continue;
      }
      results.add(SearchResultItem(
        name: name,
        author: author,
        coverUrl: cover.isEmpty ? null : cover,
        intro: intro,
        lastChapter: lastChapter,
        bookUrl: _abs(base, bookUrl),
        sourceId: source.id ?? 0,
        sourceName: source.name,
      ));
      if (results.length >= 50) break;
    }
    return results;
  }

  static Future<List<TocItem>> toc(BookSource source, String bookUrl) async {
    final rule = jsonDecode(source.json) as Map<String, dynamic>;
    final rawToc = rule['ruleToc'];
    final tocRule = rawToc is Map<String, dynamic>
        ? rawToc
        : <String, dynamic>{};
    final listRule = (tocRule['chapterList'] as String?) ?? '';
    final nameRule = (tocRule['chapterName'] as String?) ?? 'text';
    final urlRule = (tocRule['chapterUrl'] as String?) ?? 'href';
    final nextRule = (tocRule['nextTocUrl'] as String?) ?? '';
    if (listRule.isEmpty) return const [];

    final headers = _sourceHeaders(rule);
    final result = <TocItem>[];
    final seen = <String>{};
    String? currentUrl = bookUrl;
    String? previousUrl;
    int page = 0;

    while (currentUrl != null && page++ < 30) {
      final pageUrl = currentUrl;
      final html = await fetch(pageUrl, extraHeaders: headers);
      final document = html_parser.parse(html);
      String fillBase(String value) =>
          value.replaceAll('{{baseUrl}}', pageUrl);

      final elements = RuleSelector.elements(document, fillBase(listRule));
      for (final element in elements) {
        final name = _evalField(element, fillBase(nameRule));
        var href = _evalField(element, fillBase(urlRule));
        if (href.isEmpty) href = (element.attributes['href'] ?? '').trim();
        if (name.isEmpty || href.isEmpty) continue;
        final absolute = _abs(pageUrl, href);
        if (seen.add(absolute)) result.add(TocItem(name, absolute));
      }

      // 兼容目录页小改版：规则为空时从常见章节链接容器兜底。
      if (result.isEmpty) {
        _fallbackToc(document, pageUrl, seen, result);
      }

      if (nextRule.isEmpty) break;
      final next = _evalField(document, fillBase(nextRule));
      if (next.isEmpty) break;
      final absoluteNext = _abs(pageUrl, next);
      if (absoluteNext == previousUrl || absoluteNext == pageUrl) break;
      previousUrl = pageUrl;
      currentUrl = absoluteNext;
    }
    return result;
  }

  /// 常见中文小说站目录兜底：只接受看起来像章节链接的 a，避免把导航/推荐混入目录。
  static void _fallbackToc(
    Document document,
    String pageUrl,
    Set<String> seen,
    List<TocItem> result,
  ) {
    final candidates = <Element>[];
    try {
      candidates.addAll(document.querySelectorAll(
        '.listmain dd a, .listmain li a, .list a, .chapter a, '
        '.chapter-list a, .catalog a, .catalogue a, #list a, '
        '#chapterlist a, #listmain a',
      ));
    } catch (_) {}
    for (final node in candidates) {
      final name = cleanText(node.text).replaceAll(RegExp(r'\s+'), ' ');
      final href = (node.attributes['href'] ?? '').trim();
      if (name.isEmpty || href.isEmpty || !_looksLikeChapter(name, href)) {
        continue;
      }
      final absolute = _abs(pageUrl, href);
      if (seen.add(absolute)) result.add(TocItem(name, absolute));
    }
  }

  static bool _looksLikeChapter(String name, String href) {
    final chapter = RegExp(r'第\s*[0-9〇零一二三四五六七八九十百千万两]+\s*[章回节卷集篇部话]')
        .hasMatch(name);
    final numericPath = RegExp(r'/(?:\d+|\w*\d+)[^/]*\.html?(?:\?|#|$)',
            caseSensitive: false)
        .hasMatch(href);
    return chapter || numericPath;
  }

  static Future<String> content(BookSource source, String chapterUrl) async {
    final rule = jsonDecode(source.json) as Map<String, dynamic>;
    final rawContent = rule['ruleContent'];
    final contentRule = rawContent is Map<String, dynamic>
        ? rawContent
        : <String, dynamic>{};
    final rawSelector = (contentRule['content'] as String?) ?? '';
    final html = await fetch(
      chapterUrl,
      extraHeaders: _sourceHeaders(rule),
    );
    final document = html_parser.parse(html);
    final effectiveRule = rawSelector.replaceAll('{{baseUrl}}', chapterUrl);
    final segments = effectiveRule.split('##');
    final selector = segments.first;
    String text;
    if (selector.isEmpty) {
      text = '';
    } else if (selector.endsWith('html') || selector.endsWith('htmls')) {
      text = htmlToText(RuleSelector.string(document, selector));
    } else {
      text = cleanText(RuleSelector.string(document, selector));
    }
    if (segments.length > 1) {
      text = _stripRegex(text, segments.sublist(1).join('##'));
    }

    final replaceRegex = contentRule['replaceRegex'] as String?;
    if (replaceRegex != null && replaceRegex.contains('##')) {
      final split = replaceRegex.indexOf('##');
      final pattern = replaceRegex.substring(0, split);
      final replacement = replaceRegex.substring(split + 2);
      if (pattern.isEmpty) {
        text = _stripRegex(text, replacement);
      } else {
        try {
          text = text.replaceAll(
            RegExp(pattern, multiLine: true, dotAll: true),
            replacement,
          );
        } catch (_) {}
      }
    }
    if (text.trim().isEmpty) throw const HttpException('正文内容为空');
    return text;
  }

  static bool _hasKeywordPlaceholder(String value) {
    return value.contains('{{key}}') ||
        value.contains('{{KEY}}') ||
        value.contains('{{Key}}');
  }

  static bool _matchesKeyword(
    String keyword,
    String name,
    String author,
    String intro,
    String lastChapter,
  ) {
    final key = keyword.trim().toLowerCase();
    if (key.isEmpty) return true;
    final haystack = '$name $author $intro $lastChapter'.toLowerCase();
    // 至少按完整关键词命中；中文关键词过长时再允许连续片段命中。
    if (haystack.contains(key)) return true;
    if (key.length >= 4) {
      final pieces = <String>[];
      for (int i = 0; i + 2 <= key.length; i += 2) {
        pieces.add(key.substring(i, i + 2));
      }
      return pieces.isNotEmpty && pieces.every(haystack.contains);
    }
    return false;
  }

  static String _evalField(Object root, String rule) {
    if (rule.trim().isEmpty) return '';
    final buffer = StringBuffer();
    for (final part in rule.split('&&')) {
      final segments = part.split('##');
      var value = RuleSelector.string(root, segments.first);
      if (segments.length > 1) {
        value = _stripRegex(value, segments.sublist(1).join('##'));
      }
      buffer.write(value.trim());
    }
    return buffer.toString();
  }

  static String _stripRegex(String value, String spec) {
    for (final raw in spec.split('|')) {
      final pattern = raw.trim();
      if (pattern.isEmpty) continue;
      try {
        value = value.replaceAll(
          RegExp(pattern, multiLine: true, dotAll: true),
          '',
        );
      } catch (_) {}
    }
    return value.trim();
  }

  static String _abs(String base, String url) {
    try {
      if (url.startsWith('http://') || url.startsWith('https://')) return url;
      return Uri.parse(base).resolve(url).toString();
    } catch (_) {
      return url;
    }
  }
}
