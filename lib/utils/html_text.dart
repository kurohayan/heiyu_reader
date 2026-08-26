import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

const Set<String> _blockTags = {
  'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'li', 'ul', 'ol', 'section', 'article', 'blockquote',
  'tr', 'table', 'dd', 'dt', 'figcaption', 'header', 'footer',
};

const Set<String> _skipTags = {
  'script', 'style', 'noscript', 'iframe', 'svg', 'form', 'input',
  'button', 'select', 'nav', 'aside',
};

/// 将 HTML 片段转换为适合阅读的纯文本（保留段落结构）
String htmlToText(String html) {
  final doc = html_parser.parseFragment(html);
  final buf = StringBuffer();
  _walk(doc, buf);
  return cleanText(buf.toString());
}

void _walk(Node node, StringBuffer buf) {
  for (final child in node.nodes) {
    if (child.nodeType == Node.TEXT_NODE) {
      buf.write(child.text);
    } else if (child is Element) {
      final tag = child.localName?.toLowerCase() ?? '';
      if (_skipTags.contains(tag)) continue;
      if (tag == 'br') {
        buf.write('\n');
        continue;
      }
      final isBlock = _blockTags.contains(tag);
      if (isBlock) buf.write('\n');
      _walk(child, buf);
      if (isBlock) buf.write('\n');
    }
  }
}

/// 规范化文本：去除空白字符噪音、合并多余空行
String cleanText(String raw) {
  final lines = raw.split('\n').map((l) {
    var s = l.replaceAll(' ', ' ').replaceAll('　', ' ');
    s = s.replaceAll(RegExp(r'[ \t]+'), ' ');
    return s.trim();
  }).toList();

  final out = <String>[];
  int blanks = 0;
  for (final l in lines) {
    if (l.isEmpty) {
      blanks++;
      if (blanks <= 1) out.add('');
    } else {
      blanks = 0;
      out.add(l);
    }
  }
  while (out.isNotEmpty && out.first.isEmpty) {
    out.removeAt(0);
  }
  while (out.isNotEmpty && out.last.isEmpty) {
    out.removeLast();
  }
  return out.join('\n');
}
