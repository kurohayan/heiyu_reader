import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../engine/source_engine.dart';
import '../models/models.dart';
import '../theme.dart';
import 'book_detail_page.dart';

class SearchPage extends StatefulWidget {
  const SearchPage({super.key});

  @override
  State<SearchPage> createState() => _SearchPageState();
}

enum _SourceState { loading, done, error }

class _SearchPageState extends State<SearchPage> {
  final TextEditingController _controller = TextEditingController();
  final List<SearchResultItem> _results = [];
  final Map<String, _SourceState> _sourceStates = {};
  final Set<String> _failedSources = {};
  bool _searching = false;
  bool _searched = false;
  int _page = 1;
  bool _hasMore = false;
  String _keyword = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search({bool loadMore = false}) async {
    final kw = _controller.text.trim();
    if (kw.isEmpty) return;

    if (!loadMore) {
      setState(() {
        _results.clear();
        _sourceStates.clear();
        _failedSources.clear();
        _searching = true;
        _searched = true;
        _page = 1;
        _keyword = kw;
      });
    } else {
      setState(() {
        _searching = true;
        _page++;
        for (final s in _sourceStates.keys.toList()) {
          if (!_failedSources.contains(s)) {
            _sourceStates[s] = _SourceState.loading;
          }
        }
      });
    }

    final sources = await AppDatabase.instance.enabledSources();
    if (!mounted) return;
    if (sources.isEmpty) {
      setState(() => _searching = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先在「书源」页添加并启用书源')),
      );
      return;
    }

    bool anyPageTpl = false;

    Future<void> runOne(BookSource src) async {
      try {
        final items = await SourceEngine.search(src, _keyword, page: _page);
        if (!mounted) return;
        setState(() {
          _results.addAll(items);
          _sourceStates[src.name] = _SourceState.done;
          if (items.isNotEmpty && _peekSearchUrl(src.json).contains('{{page}}')) {
            anyPageTpl = true;
          }
        });
      } catch (_) {
        if (!mounted) return;
        setState(() {
          _sourceStates[src.name] = _SourceState.error;
          _failedSources.add(src.name);
        });
      }
    }

    await Future.wait([
      for (final src in sources)
        if (!loadMore || !_failedSources.contains(src.name)) runOne(src),
    ]);
    if (!mounted) return;
    setState(() {
      _searching = false;
      _hasMore = anyPageTpl;
    });
  }

  String _peekSearchUrl(String json) {
    try {
      final m = RegExp(r'"searchUrl"\s*:\s*"((?:[^"\\]|\\.)*)"')
          .firstMatch(json);
      return m?.group(1) ?? '';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('搜索')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: '搜索书名、作者…',
                      prefixIcon: Icon(Icons.search, color: kSubText),
                      filled: true,
                      fillColor: kCard,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: _searching ? null : () => _search(),
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccent,
                    foregroundColor: const Color(0xFF241A06),
                    minimumSize: const Size(64, 48),
                  ),
                  child: const Text('搜索'),
                ),
              ],
            ),
          ),
          if (_searched) _statusBar(),
          Expanded(
            child: !_searched
                ? _hint()
                : _results.isEmpty && !_searching
                    ? _noResult()
                    : _list(),
          ),
        ],
      ),
    );
  }

  Widget _hint() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.travel_explore,
              size: 56, color: kAccent.withValues(alpha: 0.3)),
          const SizedBox(height: 14),
          Text(
            '聚合搜索所有已启用的书源',
            style: TextStyle(color: kSubText, fontSize: 13.5),
          ),
        ],
      ),
    );
  }

  Widget _noResult() {
    return Center(
      child: Text('没有找到相关书籍', style: TextStyle(color: kSubText)),
    );
  }

  Widget _statusBar() {
    if (_sourceStates.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 34,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          for (final e in _sourceStates.entries)
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: kCard,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (e.value == _SourceState.loading)
                    const SizedBox(
                      width: 10,
                      height: 10,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    )
                  else
                    Icon(
                      e.value == _SourceState.done
                          ? Icons.check
                          : Icons.close,
                      size: 12,
                      color: e.value == _SourceState.done
                          ? const Color(0xFF6FCE7F)
                          : const Color(0xFFE0655A),
                    ),
                  const SizedBox(width: 5),
                  Text(
                    e.key,
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _list() {
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 30),
      itemCount: _results.length + (_hasMore ? 1 : 0),
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        if (i >= _results.length) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Center(
              child: _searching
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      onPressed: () => _search(loadMore: true),
                      child: const Text('加载更多'),
                    ),
            ),
          );
        }
        final item = _results[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            item.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 15),
          ),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              [
                if (item.author.isNotEmpty) item.author,
                if (item.lastChapter != null && item.lastChapter!.isNotEmpty)
                  item.lastChapter!,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: kSubText),
            ),
          ),
          trailing: Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: kAccent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              item.sourceName,
              style: TextStyle(fontSize: 10.5, color: kAccent),
            ),
          ),
          onTap: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => BookDetailPage(item: item),
              ),
            );
          },
        );
      },
    );
  }
}
