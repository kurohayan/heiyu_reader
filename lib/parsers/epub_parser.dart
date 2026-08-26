import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:xml/xml.dart';

import '../models/models.dart';
import '../utils/html_text.dart';

const Set<String> _epubSkipTags = {
  'script', 'style', 'noscript', 'iframe', 'svg', 'form', 'input',
  'button', 'select', 'nav', 'aside', 'video', 'audio', 'link', 'meta',
};

const Set<String> _epubBlockTags = {
  'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'li', 'ul', 'ol', 'section', 'article', 'blockquote',
  'tr', 'table', 'dd', 'dt', 'figcaption', 'figure', 'header', 'footer',
};

class EpubData {
  final Archive _archive;
  final Map<String, ArchiveFile> _entries = {};
  final String title;
  final String author;
  final List<EpubChapter> chapters;
  final Uint8List? coverBytes;
  final String coverExt;

  EpubData._({
    required Archive archive,
    required this.title,
    required this.author,
    required this.chapters,
    this.coverBytes,
    this.coverExt = 'jpg',
  }) : _archive = archive {
    for (final f in _archive.files) {
      if (!f.isFile) continue;
      _entries[_norm(f.name)] = f;
    }
  }

  static String _norm(String path) {
    var p = path.replaceAll('\\', '/');
    while (p.startsWith('/')) {
      p = p.substring(1);
    }
    return Uri.decodeComponent(p);
  }

  ArchiveFile? _entry(String path) {
    return _entries[_norm(path)] ?? _entries[path];
  }

  String? entryText(String path) {
    final f = _entry(path);
    if (f == null) return null;
    final content = f.content;
    if (content is List<int>) return utf8.decode(content, allowMalformed: true);
    return null;
  }

  final Map<String, Uint8List?> _imageCache = {};

  /// 提取章节片段（文字段 + 图片段，保持原始顺序）
  List<ReaderSegment> chapterSegments(int index) {
    if (index < 0 || index >= chapters.length) return const [];
    final html = entryText(chapters[index].href);
    if (html == null) return [const ReaderSegment.text('（章节内容缺失）')];
    final doc = html_parser.parse(html);
    final body = doc.body ?? doc.documentElement;
    if (body == null) return [ReaderSegment.text(cleanText(html))];

    final segs = <ReaderSegment>[];
    final buf = StringBuffer();

    void flush() {
      final t = cleanText(buf.toString());
      if (t.isNotEmpty) segs.add(ReaderSegment.text(t));
      buf.clear();
    }

    void walk(Node node) {
      for (final child in node.nodes) {
        if (child.nodeType == Node.TEXT_NODE) {
          buf.write(child.text);
          continue;
        }
        if (child is! Element) continue;
        final tag = child.localName?.toLowerCase() ?? '';
        if (_epubSkipTags.contains(tag)) continue;
        if (tag == 'img') {
          final src = (child.attributes['src'] ?? '').trim();
          if (src.isNotEmpty && !src.startsWith('data:')) {
            flush();
            segs.add(ReaderSegment.image(src));
          }
          continue;
        }
        if (tag == 'br') {
          buf.write('\n');
          continue;
        }
        if (_epubBlockTags.contains(tag)) {
          buf.write('\n');
          walk(child);
          buf.write('\n');
          continue;
        }
        walk(child);
      }
    }

    walk(body);
    flush();
    if (segs.isEmpty) return [const ReaderSegment.text('（本页无内容）')];
    return segs;
  }

  /// 提取章节纯文本（图片忽略，兼容旧调用）
  String chapterContent(int index) {
    final segs = chapterSegments(index);
    return [
      for (final s in segs)
        if (!s.isImage) s.text!,
    ].join('\n');
  }

  /// 解析章节内的图片引用（相对路径按章节所在目录解析），返回图片字节（带缓存）
  Uint8List? imageBytes(String chapterHref, String src) {
    var s = src.trim();
    final q = s.indexOf(RegExp(r'[?#]'));
    if (q > 0) s = s.substring(0, q);
    final key = '$chapterHref|$s';
    if (_imageCache.containsKey(key)) return _imageCache[key];
    final dir = EpubParser._dirOf(chapterHref);
    final full = EpubParser._resolve(dir, s);
    final entry = _entry(full);
    Uint8List? bytes;
    final content = entry?.content;
    if (content is List<int>) bytes = Uint8List.fromList(content);
    _imageCache[key] = bytes;
    return bytes;
  }
}

class EpubParser {
  /// 解析 EPUB：元数据、spine 章节、NCX 标题、封面
  static EpubData parse(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = <String, ArchiveFile>{};
    for (final f in archive.files) {
      if (f.isFile) files[f.name] = f;
    }

    String? textOf(String name) {
      for (final e in files.entries) {
        if (_samePath(e.key, name)) {
          final c = e.value.content;
          if (c is List<int>) return utf8.decode(c, allowMalformed: true);
        }
      }
      return null;
    }

    // 1. container.xml → OPF 路径
    String opfPath = '';
    final container = textOf('META-INF/container.xml');
    if (container != null) {
      try {
        final doc = XmlDocument.parse(container);
        final rootfile = doc.descendantElements
            .firstWhere((e) => e.localName == 'rootfile',
                orElse: () => XmlElement(XmlName('x')));
        opfPath = rootfile.getAttribute('full-path') ?? '';
      } catch (_) {}
    }
    if (opfPath.isEmpty) {
      // 兜底：直接找 .opf
      for (final name in files.keys) {
        if (name.toLowerCase().endsWith('.opf')) {
          opfPath = name;
          break;
        }
      }
    }

    String title = '未命名';
    String author = '';
    final manifest = <String, _ManifestItem>{};
    final spineIds = <String>[];
    String? ncxId;
    String? coverMetaId;
    final opfDir = _dirOf(opfPath);

    final opfText = textOf(opfPath);
    if (opfText != null) {
      try {
        final doc = XmlDocument.parse(opfText);
        for (final e in doc.descendantElements) {
          switch (e.localName) {
            case 'title':
              final t = e.innerText.trim();
              if (t.isNotEmpty && title == '未命名') title = t;
            case 'creator':
              final a = e.innerText.trim();
              if (a.isNotEmpty && author.isEmpty) author = a;
            case 'item':
              final id = e.getAttribute('id') ?? '';
              manifest[id] = _ManifestItem(
                href: e.getAttribute('href') ?? '',
                mediaType: e.getAttribute('media-type') ?? '',
                properties: e.getAttribute('properties') ?? '',
              );
            case 'itemref':
              final idref = e.getAttribute('idref');
              if (idref != null) spineIds.add(idref);
          }
        }
        // NCX: spine toc 属性或 manifest 中的 ncx
        final spineEl = doc.descendantElements
            .firstWhere((e) => e.localName == 'spine',
                orElse: () => XmlElement(XmlName('x')));
        ncxId = spineEl.getAttribute('toc');
        if (ncxId == null) {
          for (final e in manifest.entries) {
            if (e.value.mediaType == 'application/x-dtbncx+xml') {
              ncxId = e.key;
              break;
            }
          }
        }
        for (final e in doc.descendantElements) {
          if (e.localName == 'meta' &&
              e.getAttribute('name') == 'cover') {
            coverMetaId = e.getAttribute('content');
          }
        }
      } catch (_) {}
    }

    // 2. spine → 章节
    final chapters = <EpubChapter>[];
    final chapterPaths = <String>[];
    for (final id in spineIds) {
      final item = manifest[id];
      if (item == null) continue;
      if (!item.mediaType.contains('html')) continue;
      final full = _resolve(opfDir, item.href);
      chapters.add(EpubChapter('', full));
      chapterPaths.add(full);
    }

    // 3. NCX 标题映射
    final ncxTitles = <String, String>{};
    if (ncxId != null && manifest[ncxId] != null) {
      final ncxText = textOf(_resolve(opfDir, manifest[ncxId]!.href));
      if (ncxText != null) {
        try {
          final doc = XmlDocument.parse(ncxText);
          final dir = _dirOf(_resolve(opfDir, manifest[ncxId]!.href));
          XmlElement? currentPoint;
          String currentLabel = '';
          for (final e in doc.descendantElements) {
            if (e.localName == 'navPoint') {
              currentPoint = e;
              currentLabel = '';
            } else if (e.localName == 'text' && currentPoint != null) {
              final t = e.innerText.trim();
              if (t.isNotEmpty && currentLabel.isEmpty) currentLabel = t;
            } else if (e.localName == 'content' && currentPoint != null) {
              final src = e.getAttribute('src') ?? '';
              if (src.isNotEmpty && currentLabel.isNotEmpty) {
                final cleanSrc = src.split('#').first;
                ncxTitles[_resolve(dir, cleanSrc)] = currentLabel;
                currentPoint = null;
              }
            }
          }
        } catch (_) {}
      }
    }

    // 应用 NCX 标题；缺失的稍后用 xhtml <title> 补
    final titled = <EpubChapter>[];
    for (int i = 0; i < chapters.length; i++) {
      final path = chapterPaths[i];
      var t = ncxTitles[path] ?? '';
      if (t.isEmpty) {
        // 从 xhtml 中提取 <title> 或 h1/h2
        t = _extractXhtmlTitle(archive, path);
      }
      if (t.isEmpty) t = '章节 ${i + 1}';
      titled.add(EpubChapter(t, path));
    }

    // 4. 封面
    Uint8List? coverBytes;
    String coverExt = 'jpg';
    ArchiveFile? coverFile;
    String? coverHref;
    for (final item in manifest.values) {
      if (item.properties.split(RegExp(r'\s+')).contains('cover-image')) {
        coverHref = item.href;
        break;
      }
    }
    if (coverHref == null && coverMetaId != null) {
      coverHref = manifest[coverMetaId]?.href;
    }
    if (coverHref != null) {
      final full = _resolve(opfDir, coverHref);
      for (final f in archive.files) {
        if (f.isFile && _samePath(f.name, full)) {
          coverFile = f;
          break;
        }
      }
    }
    if (coverFile == null) {
      // 兜底：找名为 cover.jpg/png 的文件
      for (final f in archive.files) {
        final n = f.name.toLowerCase();
        if (f.isFile &&
            (n.endsWith('cover.jpg') ||
                n.endsWith('cover.jpeg') ||
                n.endsWith('cover.png'))) {
          coverFile = f;
          break;
        }
      }
    }
    if (coverFile != null) {
      final c = coverFile.content;
      if (c is List<int>) coverBytes = Uint8List.fromList(c);
      final lower = coverFile.name.toLowerCase();
      if (lower.endsWith('.png')) coverExt = 'png';
    }

    return EpubData._(
      archive: archive,
      title: title,
      author: author,
      chapters: titled.isEmpty
          ? [const EpubChapter('全文', '')]
          : titled,
      coverBytes: coverBytes,
      coverExt: coverExt,
    );
  }

  static String _extractXhtmlTitle(Archive archive, String path) {
    try {
      for (final f in archive.files) {
        if (!f.isFile || !_samePath(f.name, path)) continue;
        final c = f.content;
        if (c is! List<int>) return '';
        final html = utf8.decode(c, allowMalformed: true);
        final doc = html_parser.parse(html);
        for (final sel in ['h1', 'h2', 'h3', 'title']) {
          final els = doc.getElementsByTagName(sel);
          if (els.isNotEmpty) {
            final t = els.first.text.trim();
            if (t.isNotEmpty && t.length <= 60) return t;
          }
        }
        return '';
      }
    } catch (_) {}
    return '';
  }

  static bool _samePath(String a, String b) {
    return EpubData._norm(a) == EpubData._norm(b);
  }

  static String _dirOf(String path) {
    final p = path.replaceAll('\\', '/');
    final i = p.lastIndexOf('/');
    return i <= 0 ? '' : p.substring(0, i);
  }

  /// 解析相对路径（含 ../ 与 URL 编码）
  static String _resolve(String dir, String href) {
    var h = href;
    try {
      h = Uri.decodeComponent(h);
    } catch (_) {}
    h = h.replaceAll('\\', '/');
    if (h.startsWith('/')) return h.substring(1);
    final parts = <String>[
      if (dir.isNotEmpty) ...dir.split('/'),
      ...h.split('/'),
    ];
    final stack = <String>[];
    for (final part in parts) {
      if (part.isEmpty || part == '.') continue;
      if (part == '..') {
        if (stack.isNotEmpty) stack.removeLast();
      } else {
        stack.add(part);
      }
    }
    return stack.join('/');
  }
}

class _ManifestItem {
  final String href;
  final String mediaType;
  final String properties;
  _ManifestItem({
    required this.href,
    required this.mediaType,
    required this.properties,
  });
}
