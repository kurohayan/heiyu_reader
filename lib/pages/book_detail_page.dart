import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../engine/source_engine.dart';
import '../models/models.dart';
import '../state/app_state.dart';
import '../theme.dart';
import 'reader_page.dart';

class BookDetailPage extends StatefulWidget {
  final SearchResultItem item;
  const BookDetailPage({super.key, required this.item});

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  Book? _shelfBook;
  List<TocItem> _toc = [];
  bool _loadingToc = true;
  String? _tocError;
  bool _adding = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final src = await AppDatabase.instance.sourceById(widget.item.sourceId);
    final existing = await AppDatabase.instance
        .findOnlineBook(widget.item.bookUrl, widget.item.sourceId);
    if (!mounted) return;
    setState(() {
      _shelfBook = existing;
    });
    if (src == null) {
      setState(() {
        _loadingToc = false;
        _tocError = '书源不存在或已被删除';
      });
      return;
    }
    try {
      final toc = await SourceEngine.toc(src, widget.item.bookUrl);
      if (!mounted) return;
      setState(() {
        _toc = toc;
        _loadingToc = false;
        if (toc.isEmpty) {
          _tocError = '未获取到目录，书源规则可能不匹配';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loadingToc = false;
        _tocError = '目录加载失败：$e';
      });
    }
  }

  Future<Book> _ensureShelfBook() async {
    if (_shelfBook != null) return _shelfBook!;
    final book = Book(
      title: widget.item.name,
      author: widget.item.author,
      coverUrl: widget.item.coverUrl,
      intro: widget.item.intro,
      type: 'online',
      origin: widget.item.bookUrl,
      sourceId: widget.item.sourceId,
      sourceName: widget.item.sourceName,
    );
    await AppDatabase.instance.insertBook(book);
    _shelfBook = book;
    AppState.notifyShelf();
    if (mounted) setState(() {});
    return book;
  }

  Future<void> _addToShelf() async {
    if (_shelfBook != null || _adding) return;
    setState(() => _adding = true);
    await _ensureShelfBook();
    if (mounted) {
      setState(() => _adding = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已加入书架')),
      );
    }
  }

  Future<void> _readAt(int index) async {
    final book = await _ensureShelfBook();
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ReaderPage(book: book, initialChapter: index),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
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
                    height: 116,
                    child: item.coverUrl != null
                        ? Image.network(
                            item.coverUrl!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => _coverFallback(),
                          )
                        : _coverFallback(),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 6),
                      if (item.author.isNotEmpty)
                        Text(
                          '作者：${item.author}',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: kSubText,
                          ),
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
                          '书源：${item.sourceName}',
                          style: TextStyle(
                            fontSize: 10.5,
                            color: kAccent,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton(
                              onPressed:
                                  _shelfBook != null ? null : _addToShelf,
                              style: FilledButton.styleFrom(
                                backgroundColor: _shelfBook != null
                                    ? kCard
                                    : kAccent,
                                foregroundColor: _shelfBook != null
                                    ? kSubText
                                    : const Color(0xFF241A06),
                              ),
                              child: Text(
                                _shelfBook != null
                                    ? '已在书架'
                                    : (_adding ? '加入中…' : '加入书架'),
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: FilledButton(
                              onPressed:
                                  _toc.isEmpty ? null : () => _readAt(0),
                              style: FilledButton.styleFrom(
                                backgroundColor: kCard,
                                foregroundColor: kAccent,
                              ),
                              child: const Text(
                                '开始阅读',
                                style: TextStyle(fontSize: 13),
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
          if (item.intro != null && item.intro!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: ExpandableIntro(text: item.intro!),
            ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
            child: Row(
              children: [
                const Text('目录', style: TextStyle(fontSize: 15)),
                const SizedBox(width: 8),
                if (!_loadingToc && _toc.isNotEmpty)
                  Text(
                    '共 ${_toc.length} 章',
                    style: TextStyle(fontSize: 12, color: kSubText),
                  ),
                const Spacer(),
                if (_tocError != null)
                  TextButton(
                    onPressed: () {
                      setState(() {
                        _tocError = null;
                        _loadingToc = true;
                      });
                      _load();
                    },
                    child: const Text('重试'),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _loadingToc
                ? const Center(child: CircularProgressIndicator())
                : _tocError != null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            _tocError!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: kSubText,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _toc.length,
                        itemBuilder: (context, i) {
                          return ListTile(
                            dense: true,
                            title: Text(
                              _toc[i].name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13.5),
                            ),
                            onTap: () => _readAt(i),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _coverFallback() {
    return Container(
      color: kCard,
      alignment: Alignment.center,
      child: Icon(Icons.menu_book, color: kSubText, size: 30),
    );
  }
}

class ExpandableIntro extends StatefulWidget {
  final String text;
  const ExpandableIntro({super.key, required this.text});

  @override
  State<ExpandableIntro> createState() => _ExpandableIntroState();
}

class _ExpandableIntroState extends State<ExpandableIntro> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: Text(
        widget.text,
        maxLines: _expanded ? null : 2,
        overflow: _expanded ? TextOverflow.visible : TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12.5,
          color: kSubText,
          height: 1.7,
        ),
      ),
    );
  }
}
