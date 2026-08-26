import '../models/models.dart';

/// TXT 智能分章
class TxtParser {
  /// 「第X章/回/卷/节…」标题行
  static final RegExp _chapterReg = RegExp(
    r'(^|\n)[ \t]*(第[ \t]*[0-9〇零一二三四五六七八九十百千万两]{1,15}[ \t]*[章回卷节集部篇话][^\n]{0,30})',
  );

  /// 纯数字序号风格：`001. xxx` / `1、xxx`
  static final RegExp _numReg = RegExp(
    r'(^|\n)[ \t]*([0-9]{1,4}[\.、．][ \t]*[^\n]{1,40})',
  );

  static const int _chunkSize = 12000;

  static List<TxtChapter> splitChapters(String text) {
    var matches = _chapterReg.allMatches(text).toList();
    if (matches.length < 4) {
      final m2 = _numReg.allMatches(text).toList();
      if (m2.length > matches.length && m2.length >= 4) matches = m2;
    }

    if (matches.length >= 4) {
      final chapters = <TxtChapter>[];
      final starts = <int>[];
      final titles = <String>[];
      int searchFrom = 0;
      for (final m in matches) {
        final g = m.group(2);
        if (g == null) continue;
        final title = g.trim();
        if (title.isEmpty) continue;
        // 用 indexOf 定位标题（兼容新旧 Dart SDK 的 Match API）
        final titleStart = text.indexOf(title, searchFrom);
        if (titleStart < 0) continue;
        searchFrom = titleStart + title.length;
        // 过滤过近的误匹配（同一行重复）
        if (starts.isNotEmpty && titleStart - starts.last < 20) continue;
        starts.add(titleStart);
        titles.add(title.length > 42 ? title.substring(0, 42) : title);
      }
      if (starts.length >= 4) {
        // 正文开头到第一章之间若有较长内容，作为「序章」
        if (starts.first > 300) {
          chapters.add(TxtChapter('序章', 0, starts.first));
        }
        for (int i = 0; i < starts.length; i++) {
          final end = i + 1 < starts.length ? starts[i + 1] : text.length;
          if (end - starts[i] < 10) continue; // 跳过空章
          chapters.add(TxtChapter(titles[i], starts[i], end));
        }
        return chapters;
      }
    }

    // 兜底：按固定长度切块，优先在换行处断开
    final chapters = <TxtChapter>[];
    int pos = 0;
    int idx = 1;
    while (pos < text.length) {
      int end = pos + _chunkSize;
      if (end < text.length) {
        final nl = text.lastIndexOf('\n', end + 2000 < text.length ? end + 2000 : text.length);
        if (nl > pos + _chunkSize ~/ 2) end = nl + 1;
      } else {
        end = text.length;
      }
      chapters.add(TxtChapter('第 $idx 段', pos, end));
      pos = end;
      idx++;
    }
    return chapters;
  }

  /// 提取书籍开头可能的「书名 / 作者」信息行
  static ({String title, String author}) guessMeta(
    String fileName,
    String headText,
  ) {
    String title = fileName;
    final dot = title.lastIndexOf('.');
    if (dot > 0) title = title.substring(0, dot);
    String author = '';
    final lines = headText.split('\n').take(20);
    for (final l in lines) {
      final s = l.trim();
      final mAuthor = RegExp(r'^(?:作者|作\s*者)[：:]\s*(.{1,20})$')
          .firstMatch(s);
      if (mAuthor != null) {
        author = mAuthor.group(1)!.trim();
        continue;
      }
      final mTitle = RegExp(r'^(?:书名|书\s*名)[：:]\s*(.{1,40})$')
          .firstMatch(s);
      if (mTitle != null) {
        title = mTitle.group(1)!.trim();
      }
    }
    return (title: title, author: author);
  }
}
