import 'package:flutter/material.dart';

import '../theme.dart';

class _SearchHit {
  final int chapter;
  final String chapterTitle;
  final int offset;
  final String snippet;
  final int snippetStart; // 关键词在 snippet 中的位置

  const _SearchHit(
    this.chapter,
    this.chapterTitle,
    this.offset,
    this.snippet,
    this.snippetStart,
  );
}

/// 全本搜索抽屉：在可搜索章节中查找关键词，点选跳转到命中位置
Future<void> showInBookSearchSheet(
  BuildContext context, {
  required List<int> searchableChapters,
  required List<String> titles,
  required Future<String> Function(int index) chapterText,
  String? hint,
  required void Function(int chapter, int offset) onJump,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) => _InBookSearchSheet(
      searchableChapters: searchableChapters,
      titles: titles,
      chapterText: chapterText,
      hint: hint,
      onJump: (c, o) {
        Navigator.pop(ctx);
        onJump(c, o);
      },
    ),
  );
}

class _InBookSearchSheet extends StatefulWidget {
  final List<int> searchableChapters;
  final List<String> titles;
  final Future<String> Function(int index) chapterText;
  final String? hint;
  final void Function(int chapter, int offset) onJump;

  const _InBookSearchSheet({
    required this.searchableChapters,
    required this.titles,
    required this.chapterText,
    required this.onJump,
    this.hint,
  });

  @override
  State<_InBookSearchSheet> createState() => _InBookSearchSheetState();
}

class _InBookSearchSheetState extends State<_InBookSearchSheet> {
  final TextEditingController _controller = TextEditingController();
  final List<_SearchHit> _results = [];
  bool _searching = false;
  bool _searched = false;
  int _scanToken = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    final token = ++_scanToken;
    setState(() {
      _results.clear();
      _searching = true;
      _searched = true;
    });

    final needle = kw.toLowerCase();
    outer:
    for (final idx in widget.searchableChapters) {
      if (token != _scanToken || !mounted) return;
      if (_results.length >= 200) break;
      final text = await widget.chapterText(idx);
      if (text.isEmpty) continue;
      final lower = text.toLowerCase();
      var from = 0;
      var found = 0;
      while (found < 5) {
        final i = lower.indexOf(needle, from);
        if (i < 0) break;
        final start = (i - 20).clamp(0, text.length);
        final end = (i + needle.length + 30).clamp(0, text.length);
        final snippet =
            '…${text.substring(start, end).replaceAll('\n', ' ')}…';
        _results.add(
          _SearchHit(idx, widget.titles[idx], i, snippet, i - start + 1),
        );
        from = i + needle.length;
        found++;
        if (_results.length >= 200) break outer;
      }
      if (idx % 5 == 0) {
        await Future.delayed(Duration.zero);
        if (mounted) setState(() {});
      }
    }
    if (!mounted || token != _scanToken) return;
    setState(() => _searching = false);
  }

  Widget _snippet(_SearchHit hit, String keyword) {
    final s = hit.snippet;
    final start = hit.snippetStart;
    final end = (start + keyword.length).clamp(0, s.length);
    if (start < 0 || start >= s.length) {
      return Text(s,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12.5, color: kSubText, height: 1.5));
    }
    return RichText(
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      text: TextSpan(
        style: TextStyle(fontSize: 12.5, color: kSubText, height: 1.5),
        children: [
          TextSpan(text: s.substring(0, start)),
          TextSpan(
            text: s.substring(start, end),
            style: TextStyle(color: kAccent, fontWeight: FontWeight.w600),
          ),
          TextSpan(text: s.substring(end)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final kw = _controller.text.trim();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.82,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              onSubmitted: _search,
              decoration: InputDecoration(
                hintText: '搜索本书内容…',
                prefixIcon: Icon(Icons.search, color: kSubText, size: 20),
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
          if (widget.hint != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  widget.hint!,
                  style: TextStyle(fontSize: 11.5, color: kSubText),
                ),
              ),
            ),
          if (_searching)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '搜索中… 已找到 ${_results.length} 处',
                    style: TextStyle(fontSize: 12, color: kSubText),
                  ),
                ],
              ),
            )
          else if (_searched)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                _results.isEmpty ? '没有找到「$kw」' : '共 ${_results.length} 处命中',
                style: TextStyle(fontSize: 12, color: kSubText),
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: ListView.builder(
              itemCount: _results.length,
              itemBuilder: (context, i) {
                final hit = _results[i];
                return ListTile(
                  dense: true,
                  title: Text(
                    hit.chapterTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: kAccent),
                  ),
                  subtitle: _snippet(hit, kw),
                  onTap: () => widget.onJump(hit.chapter, hit.offset),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
