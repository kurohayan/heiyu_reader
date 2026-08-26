import 'package:html/dom.dart';

/// 书源规则选择器引擎（「阅读 legado」规则常用子集）
///
/// 支持语法：
/// - `class.名称` / `id.名称` / `tag.名称` / `children`
/// - 链式 `@`：`class.bookbox@tag.a@text`
/// - 索引：`class.list.0`、独立数字步骤 `tag.a@1`（负数从末尾计）
/// - 终结符：`text` / `textNodes` / `ownText` / `html`
/// - 属性：`href` / `src` / 任意属性名
/// - 回退：`rule1||rule2`
class RuleSelector {
  static List<String> strings(Object root, String rule) {
    final out = run(root, rule);
    return [
      for (final o in out)
        if (o is String && o.trim().isNotEmpty) o.trim(),
    ];
  }

  static String string(Object root, String rule) {
    final list = strings(root, rule);
    return list.isEmpty ? '' : list.first;
  }

  static List<Element> elements(Object root, String rule) {
    final out = run(root, rule);
    return [for (final o in out) if (o is Element) o];
  }

  static List<Object> run(Object root, String rule) {
    for (final candidate in rule.split('||')) {
      final c = candidate.trim();
      if (c.isEmpty) continue;
      final result = _runSingle(root, c);
      if (result.isNotEmpty) return result;
    }
    return const [];
  }

  static List<Object> _runSingle(Object root, String rule) {
    // Document / DocumentFragment 统一归一化到元素层
    Object r = root;
    if (r is Document) {
      r = r.documentElement ?? r;
    } else if (r is DocumentFragment) {
      r = r.children.isNotEmpty ? r.children.first : r;
    }
    List<Object> current = [r];
    // 按 @ 切分规则链，但保留 @css: 前缀（负向前瞻）
    for (final rawPart in rule.split(RegExp(r'@(?!css:)'))) {
      final p = rawPart.trim();
      if (p.isEmpty) continue;
      if (current.isEmpty) break;
      current = _step(current, p);
    }
    return current;
  }

  static List<Object> _step(List<Object> input, String part) {
    // 「!N」「!N:M:...」legado 语法：排除指定下标（负数从末尾计）
    if (part.startsWith('!')) {
      return _applyExcludes(input, part.substring(1));
    }
    final bang = part.indexOf('!');
    String step = part;
    String? excludeSpec;
    if (bang > 0) {
      excludeSpec = part.substring(bang + 1);
      step = part.substring(0, bang);
    }
    final result = _stepCore(input, step);
    if (excludeSpec != null) {
      return _applyExcludes(result, excludeSpec);
    }
    return result;
  }

  static List<Object> _applyExcludes(List<Object> input, String spec) {
    if (input.isEmpty) return const [];
    final n = input.length;
    final excluded = <int>{};
    for (final p in spec.split(':')) {
      final t = p.trim();
      if (t.isEmpty) continue;
      final v = int.tryParse(t);
      if (v == null) continue;
      excluded.add(v >= 0 ? v : n + v);
    }
    return [
      for (int i = 0; i < n; i++)
        if (!excluded.contains(i)) input[i],
    ];
  }

  static List<Object> _stepCore(List<Object> input, String part) {
    final elements = [for (final o in input) if (o is Element) o];

    switch (part) {
      case 'text':
        return [for (final e in elements) _norm(_textOf(e))];
      case 'textNodes':
        return [
          for (final e in elements)
            for (final n in e.nodes)
              if (n.nodeType == Node.TEXT_NODE && _norm(n.text ?? '').isNotEmpty)
                _norm(n.text ?? ''),
        ];
      case 'ownText':
        return [
          for (final e in elements)
            _norm([
              for (final n in e.nodes)
                if (n.nodeType == Node.TEXT_NODE) n.text ?? '',
            ].join('')),
        ];
      case 'html':
      case 'htmls':
        return [for (final e in elements) e.innerHtml];
      case 'all':
        return input;
      case 'children':
        return [for (final e in elements) ...e.children];
    }

    // 纯数字 → 索引选择
    final idx = int.tryParse(part);
    if (idx != null) {
      if (input.isEmpty) return const [];
      final i = idx >= 0 ? idx : input.length + idx;
      if (i < 0 || i >= input.length) return const [];
      return [input[i]];
    }

    // class.xxx.N / tag.xxx.N / id.xxx
    if (part.startsWith('class.') ||
        part.startsWith('tag.') ||
        part.startsWith('id.')) {
      final dot = part.indexOf('.');
      final kind = part.substring(0, dot);
      var rest = part.substring(dot + 1);
      int? takeIndex;
      final lastDot = rest.lastIndexOf('.');
      if (lastDot > 0) {
        final maybe = int.tryParse(rest.substring(lastDot + 1));
        if (maybe != null) {
          takeIndex = maybe;
          rest = rest.substring(0, lastDot);
        }
      }
      List<Object> out = [];
      for (final e in elements) {
        switch (kind) {
          case 'class':
            out.addAll(e.getElementsByClassName(rest));
          case 'tag':
            out.addAll(e.getElementsByTagName(rest));
          case 'id':
            final found = _byId(e, rest);
            if (found != null) out.add(found);
        }
      }
      if (takeIndex != null && out.isNotEmpty) {
        final i = takeIndex >= 0 ? takeIndex : out.length + takeIndex;
        out = (i >= 0 && i < out.length) ? [out[i]] : const [];
      }
      return out;
    }

    // @css: 前缀，或裸 CSS 选择器（含选择器特征符号）
    String? css;
    if (part.startsWith('@css:')) {
      css = part.substring(5);
    } else if (RegExp(r'[.#\[\]>\s,:+~*]').hasMatch(part)) {
      css = part;
    }
    if (css != null) {
      final out = <Object>[];
      for (final e in elements) {
        try {
          out.addAll(e.querySelectorAll(css));
        } catch (_) {}
      }
      return out;
    }

    // 默认按属性处理（href / src / title / data-xx …）
    return [
      for (final e in elements)
        if ((e.attributes[part] ?? '').trim().isNotEmpty)
          (e.attributes[part] ?? '').trim(),
    ];
  }

  static String _textOf(Element e) => e.text;

  static String _norm(String s) {
    return s
        .replaceAll(' ', ' ')
        .replaceAll('　', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static Element? _byId(Element root, String id) {
    for (final e in root.querySelectorAll('*')) {
      if (e.id == id) return e;
    }
    return null;
  }
}
