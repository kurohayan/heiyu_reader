import 'dart:convert';

import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../engine/source_engine.dart';
import '../models/models.dart';
import '../services/importer.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/book_cover.dart';

/// 书架书籍详情（从阅读器进入，目录列表复用阅读器内存数据）
class ShelfBookDetailPage extends StatefulWidget {
  final Book book;
  final List<String> titles;
  final int currentChapter;
  final List<TocItem>? tocItems; // 在线书的目录（阅读器已加载则复用）

  const ShelfBookDetailPage({
    super.key,
    required this.book,
    required this.titles,
    required this.currentChapter,
    this.tocItems,
  });

  @override
  State<ShelfBookDetailPage> createState() => _ShelfBookDetailPageState();
}

class _ShelfBookDetailPageState extends State<ShelfBookDetailPage> {
  List<ReadingBookmark> _bookmarks = [];
  List<TocItem>? _toc;
  bool _tocLoading = false;
  int _cachedCount = 0;

  @override
  void initState() {
    super.initState();
    _loadBookmarks();
    _initToc();
  }

  Future<void> _loadBookmarks() async {
    final id = widget.book.id;
    if (id == null) return;
    final items = await AppDatabase.instance.bookmarksOf(id);
    if (mounted) setState(() => _bookmarks = items);
  }

  Future<void> _removeBookmark(ReadingBookmark b) async {
    await AppDatabase.instance.deleteBookmark(b.id!);
    await _loadBookmarks();
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 在线书：准备目录（缓存/换源用）与已缓存章节数
  Future<void> _initToc() async {
    final book = widget.book;
    if (!book.isOnline || book.id == null) return;
    _toc ??= widget.tocItems;
    if (_toc == null && book.sourceId != null && book.origin != null) {
      setState(() => _tocLoading = true);
      try {
        final src = await AppDatabase.instance.sourceById(book.sourceId!);
        if (src != null) _toc = await SourceEngine.toc(src, book.origin!);
      } catch (_) {}
    }
    final count = await AppDatabase.instance.cachedChapterCount(book.id!);
    if (mounted) {
      setState(() {
        _cachedCount = count;
        _tocLoading = false;
      });
    }
  }

  // ---------- 整本缓存 ----------

  Future<void> _openCacheSheet() async {
    final book = widget.book;
    final toc = _toc;
    if (book.id == null) return;
    if (toc == null || toc.isEmpty) {
      _toast(_tocLoading ? '目录加载中，请稍候' : '目录不可用，无法缓存');
      return;
    }
    final src = await AppDatabase.instance.sourceById(book.sourceId ?? 0);
    if (src == null) {
      _toast('书源已删除，无法缓存');
      return;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isDismissible: false,
      enableDrag: false,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _CacheSheet(book: book, source: src, toc: toc),
    );
    await _initToc();
  }

  // ---------- 换源 ----------

  Future<void> _openSwitchSourceSheet() async {
    final book = widget.book;
    final sources = await AppDatabase.instance.enabledSources();
    if (!mounted) return;
    if (sources.isEmpty) {
      _toast('没有可用书源');
      return;
    }
    final picked =
        await showModalBottomSheet<(SearchResultItem, BookSource)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _SwitchSourceSheet(book: book, sources: sources),
    );
    if (picked == null || !mounted) return;
    final (result, src) = picked;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('换源到「${src.name}」？'),
        content: const Text(
          '将清除本书已缓存的章节，阅读进度会尽量保留（按章节序号对齐）。',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('换源'),
          ),
        ],
      ),
    );
    if (ok != true) return;

    book.origin = result.bookUrl;
    book.sourceId = src.id;
    book.sourceName = src.name;
    await AppDatabase.instance.updateBook(book);
    if (book.id != null) {
      await AppDatabase.instance.clearChapterCacheForBook(book.id!);
    }
    AppState.notifyShelf();
    _toast('已换源到「${src.name}」');
    if (mounted) Navigator.pop(context, 'reload');
  }

  // ---------- 净化规则 ----------

  Future<void> _openPurifySheet() async {
    final book = widget.book;
    if (book.id == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => _PurifySheet(book: book),
    );
  }

  Future<void> _removeFromShelf() async {
    final book = widget.book;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('移除《${book.title}》？'),
        content: Text(
          book.isLocal ? '将同时删除本地文件与阅读进度' : '将移除书架条目与已缓存章节',
          style: TextStyle(color: kSubText, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('移除', style: TextStyle(color: Color(0xFFE0655A))),
          ),
        ],
      ),
    );
    if (ok != true || book.id == null || !mounted) return;
    await BookImporter.deleteBookFiles(book);
    await AppDatabase.instance.deleteBook(book.id!);
    AppState.notifyShelf();
    if (mounted) Navigator.pop(context, -1);
  }

  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final titles = widget.titles;
    return Scaffold(
      appBar: AppBar(title: const Text('书籍详情')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 84,
                    height: 112,
                    child: BookCoverView(book: book),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        book.author.isNotEmpty ? '作者：${book.author}' : '作者：未知',
                        style: TextStyle(fontSize: 12.5, color: kSubText),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: kAccent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          book.isOnline
                              ? '书源：${book.sourceName ?? "未知"}'
                              : '本地 · ${book.type.toUpperCase()}',
                          style: TextStyle(fontSize: 10.5, color: kAccent),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed: () => Navigator.pop(context),
                              style: FilledButton.styleFrom(
                                backgroundColor: kAccent,
                                foregroundColor: const Color(0xFF241A06),
                                minimumSize: const Size(0, 36),
                              ),
                              child: const Text('继续阅读',
                                  style: TextStyle(fontSize: 13)),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: OutlinedButton(
                              onPressed: _removeFromShelf,
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 36),
                                foregroundColor: const Color(0xFFE0655A),
                                side: BorderSide(
                                  color: const Color(0xFFE0655A)
                                      .withValues(alpha: 0.4),
                                ),
                              ),
                              child: const Text('移除书架',
                                  style: TextStyle(fontSize: 13)),
                            ),
                          ),
                        ],
                      ),
                      if (book.isOnline) ...[
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed:
                                    _tocLoading ? null : _openCacheSheet,
                                icon: const Icon(Icons.download_outlined,
                                    size: 16),
                                label: Text(
                                  _cachedCount > 0
                                      ? '缓存 $_cachedCount/${_toc?.length ?? "?"}'
                                      : '整本缓存',
                                  style: const TextStyle(fontSize: 12.5),
                                ),
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(0, 34),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: _openSwitchSourceSheet,
                                icon: const Icon(Icons.swap_horiz, size: 16),
                                label: const Text('换源',
                                    style: TextStyle(fontSize: 12.5)),
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(0, 34),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _openPurifySheet,
                              icon: const Icon(
                                Icons.cleaning_services_outlined,
                                size: 16,
                              ),
                              label: const Text(
                                '净化规则',
                                style: TextStyle(fontSize: 12.5),
                              ),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size(0, 34),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_bookmarks.isNotEmpty) ...[
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Row(
                children: [
                  const Text('阅读点', style: TextStyle(fontSize: 15)),
                  const SizedBox(width: 8),
                  Text(
                    '共 ${_bookmarks.length} 条',
                    style: TextStyle(fontSize: 12, color: kSubText),
                  ),
                ],
              ),
            ),
            for (final b in _bookmarks.take(5))
              ListTile(
                dense: true,
                leading: Icon(Icons.bookmark, size: 18, color: kAccent),
                title: Text(
                  b.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13.5),
                ),
                subtitle: Text(
                  '第 ${b.chapter + 1} 章 · ${b.timeLabel}',
                  style: TextStyle(fontSize: 11.5, color: kSubText),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 18),
                  onPressed: () => _removeBookmark(b),
                ),
                onTap: () => Navigator.pop(context, b),
              ),
          ],
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Row(
              children: [
                const Text('目录', style: TextStyle(fontSize: 15)),
                const SizedBox(width: 8),
                Text(
                  '共 ${titles.length} 章',
                  style: TextStyle(fontSize: 12, color: kSubText),
                ),
                const Spacer(),
                if (book.lastChapter > 0)
                  Text(
                    '读至第 ${book.lastChapter + 1} 章',
                    style: TextStyle(fontSize: 11, color: kAccent),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.separated(
              itemCount: titles.length,
              separatorBuilder: (_, __) =>
                  const Divider(height: 1, indent: 16, endIndent: 16),
              itemBuilder: (context, i) {
                final isCurrent = i == widget.currentChapter;
                return ListTile(
                  dense: true,
                  title: Text(
                    titles[i],
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13.5,
                      color: isCurrent ? kAccent : null,
                    ),
                  ),
                  trailing: isCurrent
                      ? Icon(Icons.menu_book, size: 15, color: kAccent)
                      : null,
                  onTap: () => Navigator.pop(context, i),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 整本缓存进度抽屉
class _CacheSheet extends StatefulWidget {
  final Book book;
  final BookSource source;
  final List<TocItem> toc;

  const _CacheSheet({
    required this.book,
    required this.source,
    required this.toc,
  });

  @override
  State<_CacheSheet> createState() => _CacheSheetState();
}

class _CacheSheetState extends State<_CacheSheet> {
  int _done = 0;
  int _failures = 0;
  bool _cancelled = false;
  bool _finished = false;

  int get _total => widget.toc.length;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    final bookId = widget.book.id;
    if (bookId == null) return;
    var next = 0;

    Future<void> worker() async {
      while (true) {
        if (_cancelled || !mounted) return;
        final i = next++;
        if (i >= _total) return;
        final ch = widget.toc[i];
        final cached = await AppDatabase.instance.cachedChapter(bookId, i);
        if (cached == null) {
          try {
            final content =
                await SourceEngine.content(widget.source, ch.url);
            await AppDatabase.instance
                .cacheChapter(bookId, i, ch.name, content);
          } catch (_) {
            _failures++;
          }
        }
        if (mounted) setState(() => _done++);
      }
    }

    await Future.wait([worker(), worker(), worker()]);
    if (mounted) setState(() => _finished = true);
  }

  @override
  Widget build(BuildContext context) {
    final progress = _total == 0 ? 1.0 : _done / _total;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 20, 22, 22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _finished ? '缓存完成' : '整本缓存中…',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 14),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '$_done / $_total 章${_failures > 0 ? ' · 失败 $_failures 章' : ''}',
              style: TextStyle(fontSize: 12.5, color: kSubText),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 42,
              child: FilledButton(
                onPressed: () {
                  if (!_finished) setState(() => _cancelled = true);
                  Navigator.pop(context);
                },
                style: FilledButton.styleFrom(
                  backgroundColor:
                      _finished ? kAccent : const Color(0xFF3A4356),
                  foregroundColor:
                      _finished ? const Color(0xFF241A06) : Colors.white,
                ),
                child: Text(_finished ? '完成' : '取消'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 换源选择抽屉：跨书源搜同名书
class _SwitchSourceSheet extends StatefulWidget {
  final Book book;
  final List<BookSource> sources;

  const _SwitchSourceSheet({required this.book, required this.sources});

  @override
  State<_SwitchSourceSheet> createState() => _SwitchSourceSheetState();
}

class _SwitchSourceSheetState extends State<_SwitchSourceSheet> {
  final List<(SearchResultItem, BookSource)> _matches = [];
  final Set<String> _failed = {};
  bool _searching = true;

  @override
  void initState() {
    super.initState();
    _search();
  }

  bool _nameMatches(String a, String b) {
    final na = a.replaceAll(RegExp(r'[\s（(].*$'), '');
    final nb = b.replaceAll(RegExp(r'[\s（(].*$'), '');
    return na == nb || na.contains(nb) || nb.contains(na);
  }

  Future<void> _search() async {
    final title = widget.book.title;
    await Future.wait([
      for (final src in widget.sources)
        Future(() async {
          try {
            final items = await SourceEngine.search(src, title);
            final hits = [
              for (final r in items)
                if (_nameMatches(r.name, title)) (r, src),
            ];
            if (hits.isNotEmpty && mounted) {
              setState(() => _matches.addAll(hits));
            }
          } catch (_) {
            if (mounted) setState(() => _failed.add(src.name));
          }
        }),
    ]);
    if (mounted) setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.6,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
            child: Row(
              children: [
                const Text(
                  '换源',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 10),
                Text(
                  _searching ? '搜索中…' : '共 ${_matches.length} 个可用源',
                  style: TextStyle(fontSize: 12, color: kSubText),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _matches.isEmpty && !_searching
                ? Center(
                    child: Text(
                      '其它书源没有找到同名书籍',
                      style: TextStyle(color: kSubText, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    itemCount: _matches.length,
                    itemBuilder: (context, i) {
                      final (r, src) = _matches[i];
                      return ListTile(
                        dense: true,
                        title: Text(
                          r.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14),
                        ),
                        subtitle: Text(
                          [
                            if (r.author.isNotEmpty) r.author,
                            if (r.lastChapter != null &&
                                r.lastChapter!.isNotEmpty)
                              r.lastChapter!,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: kSubText),
                        ),
                        trailing: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: kAccent.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            src.name,
                            style: TextStyle(fontSize: 10.5, color: kAccent),
                          ),
                        ),
                        onTap: () => Navigator.pop(context, (r, src)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 净化替换规则管理（正则 → 替换）
class _PurifySheet extends StatefulWidget {
  final Book book;
  const _PurifySheet({required this.book});

  @override
  State<_PurifySheet> createState() => _PurifySheetState();
}

class _PurifySheetState extends State<_PurifySheet> {
  List<Map<String, Object?>> _rules = [];
  final _patternCtrl = TextEditingController();
  final _replaceCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    try {
      final raw = widget.book.replaceRules;
      if (raw != null && raw.isNotEmpty) {
        _rules = [
          for (final r in jsonDecode(raw) as List)
            Map<String, Object?>.from(r as Map),
        ];
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _patternCtrl.dispose();
    _replaceCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final json = _rules.isEmpty ? null : jsonEncode(_rules);
    widget.book.replaceRules = json;
    await AppDatabase.instance.updateReplaceRules(widget.book.id!, json);
    if (mounted) setState(() {});
  }

  void _addRule() {
    final pattern = _patternCtrl.text.trim();
    if (pattern.isEmpty) return;
    try {
      RegExp(pattern);
    } catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正则表达式无效')),
      );
      return;
    }
    setState(() {
      _rules.add({
        'pattern': pattern,
        'replace': _replaceCtrl.text,
        'enabled': true,
      });
      _patternCtrl.clear();
      _replaceCtrl.clear();
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.65,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
            child: Row(
              children: [
                const Text(
                  '净化规则',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(width: 10),
                Text(
                  '共 ${_rules.length} 条 · 正则替换',
                  style: TextStyle(fontSize: 12, color: kSubText),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '阅读时对正文按规则做替换，常用于去除广告水印、修正错字',
                style: TextStyle(fontSize: 11.5, color: kSubText),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
            child: Row(
              children: [
                Expanded(
                  flex: 3,
                  child: TextField(
                    controller: _patternCtrl,
                    decoration: const InputDecoration(
                      hintText: '正则，如 请记住本书首发.*',
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: _replaceCtrl,
                    decoration: const InputDecoration(
                      hintText: '替换为（可空）',
                      isDense: true,
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _addRule,
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccent,
                    foregroundColor: const Color(0xFF241A06),
                    minimumSize: const Size(48, 40),
                    padding: EdgeInsets.zero,
                  ),
                  child: const Icon(Icons.add, size: 18),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: _rules.isEmpty
                ? Center(
                    child: Text(
                      '还没有规则',
                      style: TextStyle(color: kSubText, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    itemCount: _rules.length,
                    itemBuilder: (context, i) {
                      final r = _rules[i];
                      final enabled = r['enabled'] != false;
                      return ListTile(
                        dense: true,
                        title: Text(
                          '${r['pattern']}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: enabled ? null : kSubText,
                          ),
                        ),
                        subtitle: Text(
                          '→ ${r['replace'] ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: kSubText),
                        ),
                        leading: Switch(
                          value: enabled,
                          onChanged: (v) {
                            setState(() => r['enabled'] = v);
                            _save();
                          },
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18),
                          onPressed: () {
                            setState(() => _rules.removeAt(i));
                            _save();
                          },
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
