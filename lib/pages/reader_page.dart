import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../db/app_database.dart';
import '../engine/source_engine.dart';
import '../models/models.dart';
import '../parsers/epub_parser.dart';
import '../parsers/txt_parser.dart';
import '../services/font_service.dart';
import '../services/importer.dart';
import '../services/tts_service.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../utils/purify.dart';
import '../utils/text_encoding.dart';
import '../widgets/chapter_sheet.dart';
import '../widgets/inbook_search_sheet.dart';
import 'shelf_book_detail_page.dart';

class ReaderPage extends StatefulWidget {
  final Book book;
  final int? initialChapter;

  const ReaderPage({super.key, required this.book, this.initialChapter});

  @override
  State<ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<ReaderPage> {
  final ScrollController _scroll = ScrollController();

  List<String> _titles = [];
  String? _txtFull;
  List<TxtChapter>? _txtChapters;
  EpubData? _epub;
  BookSource? _source;
  List<TocItem>? _toc;

  int _index = 0;
  String _content = '';
  List<ReaderSegment>? _epubSegments; // epub 章节的图文分段
  bool _loading = true;
  String? _error;
  String? _initError;
  bool _toolbar = false;
  double _pendingRestore = -1;
  int? _pendingSearchHit; // 搜索跳转的章内字符偏移

  // 听书
  bool _ttsActive = false;
  Timer? _sleepTimer;
  int _sleepMinutes = 0;
  Future<List<Map<String, String>>>? _voicesFuture;

  // 页脚状态（时间/电量）
  final Battery _battery = Battery();
  Timer? _footerTimer;
  int _batteryLevel = -1;
  Timer? _statTimer; // 阅读时长统计

  // 分页模式状态
  bool get _paged => ReaderSettings.pagedMode;
  PageController? _pageCtrl;
  List<_PageUnit> _pageUnits = const [];
  String _pagedJoined = '';
  int _pageIndex = 0;
  bool _pagedReady = false;
  bool _paginating = false;
  bool _pendingJumpLast = false;
  Object? _pageKey;

  ReaderTheme get _theme {
    final i = ReaderSettings.themeIndex;
    return kReaderThemes[i.clamp(0, kReaderThemes.length - 1)];
  }

  @override
  void initState() {
    super.initState();
    _index = widget.initialChapter ?? widget.book.lastChapter;
    if (widget.initialChapter == null) {
      _pendingRestore = widget.book.lastOffset;
    }
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _init();
    _refreshBattery();
    _footerTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshBattery(),
    );
    _statTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      AppDatabase.instance.addReadingStat(30);
    });
  }

  Future<void> _refreshBattery() async {
    try {
      final level = await _battery.batteryLevel;
      if (mounted) setState(() => _batteryLevel = level);
    } catch (_) {}
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    _ttsActive = false;
    TtsService.instance.stop();
    _sleepTimer?.cancel();
    _footerTimer?.cancel();
    _statTimer?.cancel();
    _saveProgress();
    _scroll.dispose();
    _pageCtrl?.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    try {
      final book = widget.book;
      if (book.type == 'txt') {
        final file = await BookImporter.resolveFile(book.path!);
        final bytes = await file.readAsBytes();
        final text = decodeTextBytes(bytes).text;
        _txtFull = text;
        _txtChapters = TxtParser.splitChapters(text);
        _titles = [for (final c in _txtChapters!) c.title];
      } else if (book.type == 'epub') {
        final file = await BookImporter.resolveFile(book.path!);
        final bytes = await file.readAsBytes();
        _epub = EpubParser.parse(bytes);
        _titles = [for (final c in _epub!.chapters) c.title];
      } else {
        if (book.sourceId == null) throw '书籍缺少书源信息';
        if (book.origin == null) throw '书籍缺少来源地址';
        _source = await AppDatabase.instance.sourceById(book.sourceId!);
        if (_source == null) throw '书源已删除，无法读取该书';
        _toc = await SourceEngine.toc(_source!, book.origin!);
        if (_toc!.isEmpty) throw '未获取到目录，书源规则可能已失效';
        _titles = [for (final t in _toc!) t.name];
      }

      if (_titles.isEmpty) throw '本书没有可阅读的章节';
      if (_index < 0 || _index >= _titles.length) {
        _index = _titles.length - 1;
      }
      await _loadChapter(_index);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initError = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _loadChapter(int idx) async {
    if (idx < 0 || idx >= _titles.length) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      String text;
      final book = widget.book;
      if (book.type == 'txt') {
        _epubSegments = null;
        final c = _txtChapters![idx];
        text = applyReplaceRules(
          _txtFull!.substring(c.start, c.end),
          book.replaceRules,
        );
      } else if (book.type == 'epub') {
        _epubSegments = [
          for (final s in _epub!.chapterSegments(idx))
            s.isImage
                ? s
                : ReaderSegment.text(
                    applyReplaceRules(s.text!, book.replaceRules)),
        ];
        text = [
          for (final s in _epubSegments!)
            if (!s.isImage) s.text!,
        ].join('\n');
      } else {
        _epubSegments = null;
        text = applyReplaceRules(
          await _onlineContent(idx),
          book.replaceRules,
        );
      }
      if (!mounted) return;
      setState(() {
        _content = text;
        _index = idx;
        _pageIndex = 0;
        _loading = false;
        _toolbar = false;
      });

      book.lastChapter = idx;
      if (book.id != null) {
        await AppDatabase.instance.updateProgress(book.id!, idx, 0);
      }
      AppDatabase.instance.addReadingStat(0, chapters: 1);

      if (_pendingRestore > 0 && !_paged) {
        final ratio = _pendingRestore.clamp(0.0, 1.0);
        _pendingRestore = -1;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          final max = _scroll.position.maxScrollExtent;
          if (max > 0) _scroll.jumpTo(max * ratio);
        });
      }

      if (_pendingSearchHit != null && !_paged) {
        _applySearchHit();
      }

      if (book.isOnline) _prefetch(idx + 1);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '章节加载失败：$e';
        _loading = false;
      });
    }
  }

  Future<String> _onlineContent(int idx) async {
    final book = widget.book;
    if (book.id != null) {
      final cached = await AppDatabase.instance.cachedChapter(book.id!, idx);
      if (cached != null) return cached;
    }
    final text = await SourceEngine.content(_source!, _toc![idx].url);
    if (book.id != null) {
      await AppDatabase.instance
          .cacheChapter(book.id!, idx, _titles[idx], text);
    }
    return text;
  }

  void _prefetch(int idx) {
    if (idx < 0 || idx >= _titles.length) return;
    final book = widget.book;
    if (book.id == null) return;
    Future<void>(() async {
      try {
        final cached = await AppDatabase.instance.cachedChapter(book.id!, idx);
        if (cached != null) return;
        final text = await SourceEngine.content(_source!, _toc![idx].url);
        await AppDatabase.instance
            .cacheChapter(book.id!, idx, _titles[idx], text);
      } catch (_) {}
    });
  }

  Future<void> _saveProgress() async {
    final book = widget.book;
    if (book.id == null) return;
    double ratio = 0;
    if (_paged && _pagedReady && _pageUnits.length > 1) {
      ratio = _pageIndex / (_pageUnits.length - 1);
    } else if (_scroll.hasClients) {
      final max = _scroll.position.maxScrollExtent;
      if (max > 0) ratio = _scroll.position.pixels / max;
    }
    await AppDatabase.instance.updateProgress(book.id!, _index, ratio);
  }

  void _toggleToolbar() {
    setState(() => _toolbar = !_toolbar);
    SystemChrome.setEnabledSystemUIMode(
      _toolbar ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
    );
  }

  /// 9 区点击手势（翻“页”=按屏幕翻一屏，章末自动换章）：
  ///   上一页 | 上一页 | 下一页
  ///   上一页 |  菜单  | 下一页
  ///   上一页 | 下一页 | 下一页
  void _handleTapZone(TapUpDetails details) {
    if (_loading) return;
    final size = MediaQuery.sizeOf(context);
    final col = details.localPosition.dx / size.width;
    final row = details.localPosition.dy / size.height;
    final x = col < 1 / 3 ? 0 : (col < 2 / 3 ? 1 : 2);
    final y = row < 1 / 3 ? 0 : (row < 2 / 3 ? 1 : 2);

    // 中心：菜单
    if (x == 1 && y == 1) {
      _toggleToolbar();
      return;
    }
    // 左侧一列 + 中上方：上一页
    if (x == 0 || (x == 1 && y == 0)) {
      _prevPage();
      return;
    }
    // 右侧一列 + 中下方：下一页
    _nextPage();
  }

  /// 一屏的滚动步长：留一行重叠，方便跟上阅读位置
  double get _pageStep {
    if (!_scroll.hasClients) return 600;
    final d = _scroll.position.viewportDimension;
    final line = ReaderSettings.fontSize * ReaderSettings.lineHeight;
    final step = d - line;
    return step > d * 0.7 ? step : d * 0.7;
  }

  void _nextPage() {
    if (_paged) {
      _pagedNext();
      return;
    }
    if (_scroll.hasClients && _scroll.position.maxScrollExtent > 0) {
      final pos = _scroll.position;
      // 章末（剩余不足一屏）→ 下一章；否则向下翻一屏
      if (pos.maxScrollExtent - pos.pixels > _pageStep * 0.5) {
        final target =
            (pos.pixels + _pageStep).clamp(0.0, pos.maxScrollExtent).toDouble();
        _scroll.animateTo(
          target,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
        );
        return;
      }
    }
    _nextChapter();
  }

  void _prevPage() {
    if (_paged) {
      _pagedPrev();
      return;
    }
    if (_scroll.hasClients && _scroll.position.pixels > 2) {
      final pos = _scroll.position;
      final target =
          (pos.pixels - _pageStep).clamp(0.0, pos.maxScrollExtent).toDouble();
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
      return;
    }
    _prevChapter();
  }

  // ---------- 分页模式 ----------

  void _pagedNext() {
    final n = _pageUnits.length;
    if (!_pagedReady || n == 0) return;
    if (_pageIndex < n - 1) {
      final ctrl = _pageCtrl;
      if (ctrl != null && ctrl.hasClients) {
        ctrl.animateToPage(
          _pageIndex + 1,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      }
    } else {
      _pageIndex = 0;
      _nextChapter();
    }
  }

  void _pagedPrev() {
    if (!_pagedReady) return;
    if (_pageIndex > 0) {
      final ctrl = _pageCtrl;
      if (ctrl != null && ctrl.hasClients) {
        ctrl.animateToPage(
          _pageIndex - 1,
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
        );
      }
    } else if (_index > 0) {
      _pendingJumpLast = true;
      _prevChapter();
    } else {
      _showPageHint('已经是第一章');
    }
  }

  /// 排版：把当前章节按屏幕尺寸切成页（每项 = 页起始字符偏移）
  void _schedulePaginate(Size area, Object key) {
    if (_paginating) return;
    _paginating = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final joined = _joinWithImages();
      final cuts = _computeCuts(area, joined.text);
      final units = _buildUnits(cuts, joined.images, joined.text.length);
      final n = units.length;
      int target = 0;
      if (n == 0) {
        _pendingJumpLast = false;
        _pendingRestore = -1;
      } else if (_pendingJumpLast) {
        target = n - 1;
        _pendingJumpLast = false;
      } else if (_pendingRestore > 0) {
        target = (_pendingRestore * (n - 1)).round().clamp(0, n - 1);
        _pendingRestore = -1;
      } else {
        target = _pageIndex.clamp(0, n - 1);
      }
      if (!mounted) return;
      setState(() {
        _pageKey = key;
        _pageUnits = units;
        _pagedJoined = joined.text;
        _pageIndex = target;
        _pagedReady = true;
        _paginating = false;
        _pageCtrl?.dispose();
        _pageCtrl = PageController(initialPage: target);
      });

      if (_pendingSearchHit != null) {
        final off = _pendingSearchHit!;
        _pendingSearchHit = null;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _jumpToOffsetInPage(off);
        });
      }
    });
  }

  /// epub：把图文分段拼成连续文本流，同时记录图片插入位置
  ({String text, List<(int, String)> images}) _joinWithImages() {
    if (_epubSegments == null) {
      return (text: _joinedText, images: const []);
    }
    final gap = ReaderSettings.paragraphGap;
    final sep = gap <= 2 ? '\n' : (gap >= 20 ? '\n\n\n' : '\n\n');
    final buf = StringBuffer();
    final images = <(int, String)>[];
    var first = true;
    for (final seg in _epubSegments!) {
      if (seg.isImage) {
        images.add((buf.length, seg.image!));
        continue;
      }
      for (final line in seg.text!.split('\n')) {
        final t = line.trim();
        if (t.isEmpty) continue;
        if (!first) buf.write(sep);
        buf.write(t);
        first = false;
      }
    }
    return (text: buf.toString(), images: images);
  }

  /// 把字符切点与图片插入点合并成页单元（文字页 / 图片页）
  List<_PageUnit> _buildUnits(
    List<int> cuts,
    List<(int, String)> images,
    int textLen,
  ) {
    final units = <_PageUnit>[];
    for (int i = 0; i < cuts.length; i++) {
      var s = cuts[i];
      final e = i + 1 < cuts.length ? cuts[i + 1] : textLen;
      for (final (off, src) in images) {
        // 落在本页区间内的图片；最后一页允许图片恰好在文末
        final inRange =
            off >= s && (off < e || (i == cuts.length - 1 && off == e));
        if (inRange) {
          if (off > s) units.add(_PageUnit.text(s, off));
          units.add(_PageUnit.image(src, off));
          s = off;
        }
      }
      if (s < e) units.add(_PageUnit.text(s, e));
    }
    if (units.isEmpty) units.add(const _PageUnit.text(0, 0));
    return units;
  }

  List<int> _computeCuts(Size area, String text) {
    final padH = ReaderSettings.pagePadding * 2;
    const headerH = 52.0; // 章名页眉
    const footerH = 44.0; // 页码页脚 + 底部留白
    final w = area.width - padH - 2;
    final hAvail = area.height - headerH - footerH;
    final style = ReaderSettings.applyTextStyle(TextStyle(
      fontSize: ReaderSettings.fontSize,
      height: ReaderSettings.lineHeight,
    ));
    if (text.isEmpty || w <= 0 || hAvail <= 0) return const [0];

    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
    );
    tp.layout(maxWidth: w);
    final metrics = tp.computeLineMetrics();
    if (metrics.isEmpty) return const [0];

    // 每行起始字符偏移
    final starts = <int>[];
    double y = 0;
    for (final m in metrics) {
      final pos = tp.getPositionForOffset(Offset(m.left, y + m.height / 2));
      starts.add(pos.offset);
      y += m.height;
    }

    // 按可用高度把行分组为页
    final cuts = <int>[0];
    double used = 0;
    for (int li = 0; li < metrics.length; li++) {
      final h = metrics[li].height;
      if (li > 0 && used + h > hAvail) {
        if (cuts.last != starts[li]) cuts.add(starts[li]);
        used = 0;
      }
      used += h;
    }
    return cuts;
  }

  String get _joinedText {
    final gap = ReaderSettings.paragraphGap;
    final sep = gap <= 2 ? '\n' : (gap >= 20 ? '\n\n\n' : '\n\n');
    return [
      for (final p in _content.split('\n'))
        if (p.trim().isNotEmpty) p.trim(),
    ].join(sep);
  }

  /// 卷页动画：页面随滑动位置绕竖直边 3D 旋转
  Widget _pageTransform(int i, Widget child) {
    if (ReaderSettings.pageAnim != 'curl') return child;
    final ctrl = _pageCtrl;
    if (ctrl == null) return child;
    return AnimatedBuilder(
      animation: ctrl,
      builder: (ctx, c) {
        double delta = 0;
        if (ctrl.hasClients && ctrl.position.hasContentDimensions) {
          final page = ctrl.page ?? ctrl.initialPage.toDouble();
          delta = (i - page).clamp(-1.0, 1.0);
        }
        if (delta == 0) return c!;
        final absDelta = delta.abs();
        final angle =
            (delta > 0 ? -1 : 1) * absDelta * (3.1415926 / 2) * 0.72;
        return Transform(
          alignment:
              delta > 0 ? Alignment.centerLeft : Alignment.centerRight,
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0015)
            ..rotateY(angle),
          child: Opacity(
            opacity: (1 - absDelta * 0.5).clamp(0.2, 1.0),
            child: c,
          ),
        );
      },
      child: child,
    );
  }

  Widget _buildPagedArea(ReaderTheme theme) {
    final hasContent = _content.isNotEmpty;
    if (_initError != null) return _errorView(_initError!, retry: _init);
    if (!hasContent && _loading) {
      return Center(child: CircularProgressIndicator(color: theme.text));
    }
    if (!hasContent && _error != null) {
      return _errorView(_error!, retry: () => _loadChapter(_index));
    }
    return LayoutBuilder(
      builder: (ctx, c) {
        final key = Object.hash(
          c.maxWidth.toInt(),
          c.maxHeight.toInt(),
          _index,
          _content.length,
          ReaderSettings.fontSize,
          ReaderSettings.lineHeight,
          ReaderSettings.pagePadding.toInt(),
          ReaderSettings.letterSpacing,
          ReaderSettings.fontKey,
          ReaderSettings.paragraphGap.toInt(),
        );
        if (_pageKey != key) {
          _schedulePaginate(Size(c.maxWidth, c.maxHeight), key);
          return Center(child: CircularProgressIndicator(color: theme.text));
        }
        final n = _pageUnits.length;
        if (n == 0) {
          return Center(
            child: Text('空白章节', style: TextStyle(color: theme.text)),
          );
        }
        final faint = theme.text.withValues(alpha: 0.45);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                  ReaderSettings.pagePadding, 6, ReaderSettings.pagePadding, 4),
              child: Text(
                _titles.isEmpty ? '' : _titles[_index],
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: faint),
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: _pageCtrl,
                itemCount: n,
                onPageChanged: (i) {
                  setState(() => _pageIndex = i);
                  _saveProgress();
                },
                itemBuilder: (ctx, i) {
                  final unit = _pageUnits[i];
                  if (unit.isImage) {
                    return _pageTransform(
                      i,
                      _epubImagePage(unit.image!, theme),
                    );
                  }
                  return _pageTransform(
                    i,
                    Padding(
                      padding: EdgeInsets.symmetric(
                          horizontal: ReaderSettings.pagePadding),
                      child: Text(
                        _pagedJoined.substring(unit.start, unit.end).trim(),
                        style: ReaderSettings.applyTextStyle(TextStyle(
                          fontSize: ReaderSettings.fontSize,
                          height: ReaderSettings.lineHeight,
                          color: theme.text,
                        )),
                      ),
                    ),
                  );
                },
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                ReaderSettings.pagePadding,
                4,
                ReaderSettings.pagePadding,
                6 + MediaQuery.paddingOf(ctx).bottom,
              ),
              child: Row(
                children: [
                  Text(
                    '第 ${_index + 1}/${_titles.length} 章 · $_footerStatus',
                    style: TextStyle(fontSize: 11, color: faint),
                  ),
                  const Spacer(),
                  Text(
                    '${_pageIndex + 1} / $n',
                    style: TextStyle(fontSize: 11, color: faint),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  void _nextChapter() {
    if (_titles.isEmpty) return;
    if (_index < _titles.length - 1) {
      _loadChapter(_index + 1);
    } else {
      _showPageHint('已经是最后一章');
    }
  }

  void _prevChapter() {
    if (_titles.isEmpty) return;
    if (_index > 0) {
      _loadChapter(_index - 1);
    } else {
      _showPageHint('已经是第一章');
    }
  }

  void _handleHorizontalDragEnd(DragEndDetails details) {
    if (_loading || _titles.length < 2) return;
    final velocity = details.primaryVelocity ?? 0;
    // 左滑下一章，右滑上一章；过滤轻微横向误触。
    if (velocity.abs() < 350) return;
    if (velocity < 0) {
      _nextChapter();
    } else {
      _prevChapter();
    }
  }

  void _showPageHint(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(milliseconds: 900),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  /// 当前书籍详情页（目录列表复用阅读器内存中的数据）
  Future<void> _openBookDetail() async {
    final result = await Navigator.push<Object>(
      context,
      MaterialPageRoute(
        builder: (_) => ShelfBookDetailPage(
          book: widget.book,
          titles: _titles,
          currentChapter: _index,
          tocItems: _toc,
        ),
      ),
    );
    if (!mounted) return;
    if (result is ReadingBookmark) {
      _jumpToBookmark(result);
    } else if (result == -1) {
      Navigator.pop(context); // 书籍已删除，退出阅读器
    } else if (result == 'reload') {
      // 换源后：用新书源重新初始化
      setState(() {
        _loading = true;
        _error = null;
        _initError = null;
        _content = '';
        _titles = [];
        _toc = null;
        _source = null;
      });
      _init();
    } else if (result is int && result != _index) {
      _loadChapter(result);
    }
  }

  /// 记录当前阅读位置为阅读点
  Future<void> _addBookmark() async {
    final book = widget.book;
    if (book.id == null || _loading || _content.isEmpty) return;
    // 存章内字符偏移（+2 与旧版比例格式区分），重排版后也能精确定位
    double offsetValue;
    if (_paged && _pagedReady && _pageUnits.isNotEmpty) {
      final u = _pageUnits[_pageIndex.clamp(0, _pageUnits.length - 1)];
      offsetValue = u.start.toDouble() + 2;
    } else if (_scroll.hasClients &&
        _scroll.position.maxScrollExtent > 0 &&
        _content.isNotEmpty) {
      final ratio =
          _scroll.position.pixels / _scroll.position.maxScrollExtent;
      offsetValue = ratio * _content.length + 2;
    } else {
      offsetValue = 0;
    }
    await AppDatabase.instance.addBookmark(ReadingBookmark(
      bookId: book.id!,
      chapter: _index,
      offset: offsetValue,
      label: _titles.isEmpty ? '第 ${_index + 1} 章' : _titles[_index],
    ));
    _showPageHint('已记录阅读点');
  }

  /// 跳到指定阅读点
  void _jumpToBookmark(ReadingBookmark b) {
    // offset > 1.5 → 新版字符偏移格式（存时 +2）；否则旧版比例格式
    final charOffset = b.offset > 1.5 ? (b.offset - 2).round() : null;

    if (b.chapter != _index) {
      if (charOffset != null) {
        _pendingSearchHit = charOffset; // 复用搜索跳转：排版完成后按偏移找页
      } else {
        _pendingRestore = b.offset;
      }
      _loadChapter(b.chapter);
      return;
    }

    if (_paged && _pagedReady && _pageUnits.isNotEmpty) {
      if (charOffset != null) {
        _jumpToOffsetInPage(charOffset);
      } else {
        final target = (b.offset * (_pageUnits.length - 1))
            .round()
            .clamp(0, _pageUnits.length - 1);
        final ctrl = _pageCtrl;
        if (ctrl != null && ctrl.hasClients) {
          ctrl.jumpToPage(target);
        }
        setState(() => _pageIndex = target);
      }
    } else if (_scroll.hasClients) {
      final max = _scroll.position.maxScrollExtent;
      if (max > 0) {
        final r = charOffset != null && _content.isNotEmpty
            ? (charOffset / _content.length).clamp(0.0, 1.0)
            : b.offset.clamp(0.0, 1.0);
        _scroll.jumpTo(max * r);
      }
    }
  }

  /// 全本搜索入口
  Future<void> _openSearchSheet() async {
    if (_titles.isEmpty || _loading) return;
    final book = widget.book;
    List<int> indexes;
    Future<String> Function(int) getter;
    String? hint;
    if (book.type == 'txt') {
      indexes = [for (int i = 0; i < _titles.length; i++) i];
      getter = (i) async {
        final c = _txtChapters![i];
        return _txtFull!.substring(c.start, c.end);
      };
    } else if (book.type == 'epub') {
      indexes = [for (int i = 0; i < _titles.length; i++) i];
      getter = (i) async => _epub!.chapterContent(i);
    } else {
      final cached = book.id == null
          ? const <(int, String)>[]
          : await AppDatabase.instance.cachedChapters(book.id!);
      indexes = [for (final e in cached) e.$1];
      final map = {for (final e in cached) e.$1: e.$2};
      getter = (i) async => map[i] ?? '';
      hint = '仅搜索已缓存章节（${indexes.length}/${_titles.length}）';
    }
    if (!mounted) return;
    await showInBookSearchSheet(
      context,
      searchableChapters: indexes,
      titles: _titles,
      chapterText: getter,
      hint: hint,
      onJump: _jumpToSearchHit,
    );
  }

  void _jumpToSearchHit(int chapter, int offset) {
    _pendingSearchHit = offset;
    if (chapter == _index) {
      _applySearchHit();
    } else {
      _loadChapter(chapter);
    }
  }

  void _applySearchHit() {
    final off = _pendingSearchHit;
    if (off == null) return;
    if (_paged) {
      if (_pagedReady && !_paginating) {
        _pendingSearchHit = null;
        _jumpToOffsetInPage(off);
      }
      // 排版中的交给 _schedulePaginate 消费
    } else {
      _pendingSearchHit = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final max = _scroll.position.maxScrollExtent;
        if (max > 0 && _content.isNotEmpty) {
          final ratio = (off / _content.length).clamp(0.0, 1.0);
          _scroll.jumpTo(max * ratio);
        }
      });
    }
  }

  void _jumpToOffsetInPage(int off) {
    for (int i = 0; i < _pageUnits.length; i++) {
      final u = _pageUnits[i];
      if (u.isImage) continue;
      if (off >= u.start && off < u.end) {
        final ctrl = _pageCtrl;
        if (ctrl != null && ctrl.hasClients) ctrl.jumpToPage(i);
        setState(() => _pageIndex = i);
        return;
      }
    }
  }

  /// 阅读点管理抽屉
  Future<void> _showBookmarks() async {
    final book = widget.book;
    if (book.id == null) return;
    var items = await AppDatabase.instance.bookmarksOf(book.id!);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kSurface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            Future<void> remove(ReadingBookmark b) async {
              await AppDatabase.instance.deleteBookmark(b.id!);
              items = await AppDatabase.instance.bookmarksOf(book.id!);
              setSheet(() {});
            }

            return SizedBox(
              height: MediaQuery.sizeOf(ctx).height * 0.55,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                    child: Row(
                      children: [
                        const Text(
                          '阅读点',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '共 ${items.length} 条',
                          style: TextStyle(fontSize: 12, color: kSubText),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: items.isEmpty
                        ? Center(
                            child: Text(
                              '还没有阅读点\n点顶栏书签图标可记录当前位置',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: kSubText, fontSize: 13, height: 1.8),
                            ),
                          )
                        : ListView.builder(
                            itemCount: items.length,
                            itemBuilder: (context, i) {
                              final b = items[i];
                              final isCurrent = b.chapter == _index;
                              return ListTile(
                                dense: true,
                                leading: Icon(
                                  Icons.bookmark,
                                  size: 18,
                                  color: isCurrent ? kAccent : kSubText,
                                ),
                                title: Text(
                                  b.label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13.5),
                                ),
                                subtitle: Text(
                                  '第 ${b.chapter + 1} 章 · ${b.timeLabel}',
                                  style: TextStyle(
                                    fontSize: 11.5,
                                    color: kSubText,
                                  ),
                                ),
                                trailing: IconButton(
                                  icon: const Icon(Icons.delete_outline,
                                      size: 18),
                                  onPressed: () => remove(b),
                                ),
                                onTap: () {
                                  Navigator.pop(ctx);
                                  _jumpToBookmark(b);
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ---------- 听书 TTS ----------

  /// 把正文切成适合朗读的分段
  List<String> _chunksOf(String text) {
    final chunks = <String>[];
    for (final p0 in text.split('\n')) {
      var p = p0.trim();
      if (p.isEmpty) continue;
      while (p.length > 260) {
        var cut = 260;
        final punct = p.lastIndexOf(RegExp(r'[。！？；]'), 260);
        if (punct > 100) cut = punct + 1;
        chunks.add(p.substring(0, cut));
        p = p.substring(cut);
      }
      if (p.isNotEmpty) chunks.add(p);
    }
    return chunks;
  }

  /// 当前阅读位置对应的朗读起点（按比例换算到分段序号）
  int _ttsStartChunkIndex(int total) {
    if (total <= 1) return 0;
    double ratio = 0;
    if (_paged && _pagedReady && _pageUnits.length > 1) {
      ratio = _pageIndex / (_pageUnits.length - 1);
    } else if (_scroll.hasClients &&
        _scroll.position.maxScrollExtent > 0) {
      ratio = _scroll.position.pixels / _scroll.position.maxScrollExtent;
    }
    return (ratio * total).floor().clamp(0, total - 1);
  }

  Future<void> _startTts() async {
    if (_ttsActive || _content.isEmpty) return;
    setState(() => _ttsActive = true);
    while (_ttsActive && mounted) {
      var chunks = _chunksOf(_content);
      // 从当前阅读位置开始朗读
      final startIdx = _ttsStartChunkIndex(chunks.length);
      if (startIdx > 0 && startIdx < chunks.length) {
        chunks = chunks.sublist(startIdx);
      }
      if (chunks.isEmpty) break;
      await TtsService.instance.speakChunks(
        chunks,
        isCancelled: () => !_ttsActive,
      );
      if (!_ttsActive || !mounted) break;
      // 本章读完 → 自动下一章
      if (_index < _titles.length - 1) {
        _nextChapter();
        while (_loading && _ttsActive && mounted) {
          await Future.delayed(const Duration(milliseconds: 120));
        }
      } else {
        break;
      }
    }
    if (mounted) setState(() => _ttsActive = false);
  }

  void _stopTts() {
    _sleepTimer?.cancel();
    _sleepMinutes = 0;
    if (_ttsActive) {
      _ttsActive = false;
      TtsService.instance.stop();
    }
    if (mounted) setState(() {});
  }

  void _setSleepTimer(int minutes, void Function(void Function()) setSheet) {
    _sleepTimer?.cancel();
    _sleepMinutes = minutes;
    if (minutes > 0) {
      _sleepTimer = Timer(Duration(minutes: minutes), _stopTts);
    }
    setSheet(() {});
    setState(() {});
  }

  void _showTtsSheet() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text(
                        '听书',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        _ttsActive
                            ? '正在朗读 第 ${_index + 1} 章'
                            : '未在朗读',
                        style: TextStyle(fontSize: 12, color: kSubText),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    height: 44,
                    child: FilledButton.icon(
                      onPressed: () {
                        if (_ttsActive) {
                          _stopTts();
                        } else {
                          _startTts();
                        }
                        setSheet(() {});
                      },
                      icon: Icon(
                        _ttsActive ? Icons.stop : Icons.play_arrow,
                      ),
                      label: Text(_ttsActive ? '停止朗读' : '开始朗读'),
                      style: FilledButton.styleFrom(
                        backgroundColor:
                            _ttsActive ? const Color(0xFF3A4356) : kAccent,
                        foregroundColor: _ttsActive
                            ? Colors.white
                            : const Color(0xFF241A06),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      const Text('语速', style: TextStyle(fontSize: 13.5)),
                      Expanded(
                        child: Slider(
                          value: TtsService.instance.rate,
                          min: 0.3,
                          max: 1.0,
                          divisions: 14,
                          onChanged: (v) {
                            TtsService.instance.setRate(v);
                            setSheet(() {});
                          },
                        ),
                      ),
                      Text(
                        TtsService.instance.rate.toStringAsFixed(2),
                        style: const TextStyle(fontSize: 12.5),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('音色', style: TextStyle(fontSize: 13.5)),
                      const SizedBox(width: 14),
                      Expanded(
                        child: FutureBuilder<List<Map<String, String>>>(
                          future: _voicesFuture ??=
                              TtsService.instance.voices(),
                          builder: (ctx, snap) {
                            final voices =
                                snap.data ?? const <Map<String, String>>[];
                            if (voices.isEmpty) {
                              return Text(
                                snap.connectionState == ConnectionState.done
                                    ? '系统默认'
                                    : '加载中…',
                                style: TextStyle(
                                  fontSize: 12.5,
                                  color: kSubText,
                                ),
                              );
                            }
                            String keyOf(Map<String, String> v) =>
                                '${v['name']}|${v['locale']}';
                            final current = TtsService.instance.voiceKey;
                            final valid = current != null &&
                                voices.any((v) => keyOf(v) == current);
                            return DropdownButton<String>(
                              value: valid ? current : null,
                              hint: const Text('系统默认'),
                              isExpanded: true,
                              underline: const SizedBox.shrink(),
                              items: [
                                for (final v in voices)
                                  DropdownMenuItem(
                                    value: keyOf(v),
                                    child: Text(
                                      '${v['name']}（${v['locale']}）',
                                      style:
                                          const TextStyle(fontSize: 13),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                              ],
                              onChanged: (key) async {
                                if (key == null) return;
                                await TtsService.instance.setVoice(key);
                                setSheet(() {});
                              },
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Text('定时', style: TextStyle(fontSize: 13.5)),
                      const SizedBox(width: 14),
                      for (final m in [0, 15, 30, 60])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(
                              m == 0 ? '关' : '$m分',
                              style: const TextStyle(fontSize: 12),
                            ),
                            selected: _sleepMinutes == m,
                            onSelected: (_) => _setSleepTimer(m, setSheet),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openToc() async {
    final picked = await showChapterSheet(
      context,
      titles: _titles,
      current: _index,
    );
    if (picked != null && picked != _index) {
      _loadChapter(picked);
    }
  }

  void _showSettings() {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheet) {
            void refresh() {
              setSheet(() {});
              setState(() {});
              ReaderSettings.save();
            }

            return ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(ctx).height * 0.85,
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(22, 18, 22, 30),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                  Row(
                    children: [
                      const Text('字号', style: TextStyle(fontSize: 13.5)),
                      Expanded(
                        child: Slider(
                          value: ReaderSettings.fontSize,
                          min: 14,
                          max: 32,
                          divisions: 18,
                          onChanged: (v) {
                            ReaderSettings.fontSize = v;
                            refresh();
                          },
                        ),
                      ),
                      Text(
                        '${ReaderSettings.fontSize.round()}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('行距', style: TextStyle(fontSize: 13.5)),
                      Expanded(
                        child: Slider(
                          value: ReaderSettings.lineHeight,
                          min: 1.3,
                          max: 2.8,
                          divisions: 15,
                          onChanged: (v) {
                            ReaderSettings.lineHeight = v;
                            refresh();
                          },
                        ),
                      ),
                      Text(
                        ReaderSettings.lineHeight.toStringAsFixed(1),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('段距', style: TextStyle(fontSize: 13.5)),
                      Expanded(
                        child: Slider(
                          value: ReaderSettings.paragraphGap,
                          min: 0,
                          max: 28,
                          divisions: 14,
                          onChanged: (v) {
                            ReaderSettings.paragraphGap = v;
                            refresh();
                          },
                        ),
                      ),
                      Text(
                        '${ReaderSettings.paragraphGap.round()}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text('字体', style: TextStyle(fontSize: 13.5)),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            for (final f in [
                              ('system', '默认'),
                              ('serif', '宋体'),
                              ('kai', '楷体'),
                              ('round', '圆体'),
                              ('hei', '黑体'),
                              if (FontService.isDownloaded('wenkai'))
                                ('wenkai', '文楷'),
                              if (FontService.isDownloaded('noto'))
                                ('noto', '思源宋'),
                              if (ReaderSettings
                                  .customFontFamily.isNotEmpty)
                                ('custom', '自定义'),
                            ])
                              ChoiceChip(
                                label: Text(
                                  f.$2,
                                  style: const TextStyle(fontSize: 12.5),
                                ),
                                selected: ReaderSettings.fontKey == f.$1,
                                onSelected: (_) {
                                  ReaderSettings.fontKey = f.$1;
                                  refresh();
                                },
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('字距', style: TextStyle(fontSize: 13.5)),
                      Expanded(
                        child: Slider(
                          value: ReaderSettings.letterSpacing,
                          min: 0,
                          max: 4,
                          divisions: 8,
                          onChanged: (v) {
                            ReaderSettings.letterSpacing = v;
                            refresh();
                          },
                        ),
                      ),
                      Text(
                        ReaderSettings.letterSpacing.toStringAsFixed(1),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('边距', style: TextStyle(fontSize: 13.5)),
                      Expanded(
                        child: Slider(
                          value: ReaderSettings.pagePadding,
                          min: 8,
                          max: 48,
                          divisions: 20,
                          onChanged: (v) {
                            ReaderSettings.pagePadding = v;
                            refresh();
                          },
                        ),
                      ),
                      Text(
                        '${ReaderSettings.pagePadding.round()}',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('亮度', style: TextStyle(fontSize: 13.5)),
                      Expanded(
                        child: Slider(
                          value: ReaderSettings.screenDim,
                          min: 0,
                          max: 0.6,
                          divisions: 12,
                          onChanged: (v) {
                            ReaderSettings.screenDim = v;
                            refresh();
                          },
                        ),
                      ),
                      Text(
                        ReaderSettings.screenDim == 0
                            ? '系统'
                            : '-${(ReaderSettings.screenDim * 100).round()}%',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('翻页', style: TextStyle(fontSize: 13.5)),
                      const SizedBox(width: 14),
                      ChoiceChip(
                        label: const Text('滚动'),
                        selected: !ReaderSettings.pagedMode,
                        onSelected: (_) {
                          ReaderSettings.pagedMode = false;
                          refresh();
                        },
                      ),
                      const SizedBox(width: 10),
                      ChoiceChip(
                        label: const Text('仿真分页'),
                        selected: ReaderSettings.pagedMode,
                        onSelected: (_) {
                          // 从滚动位置换算成比例，进入分页后跳到相近页
                          double ratio = 0;
                          if (_scroll.hasClients &&
                              _scroll.position.maxScrollExtent > 0) {
                            ratio = _scroll.position.pixels /
                                _scroll.position.maxScrollExtent;
                          }
                          _pendingRestore = ratio;
                          _pageKey = null;
                          ReaderSettings.pagedMode = true;
                          refresh();
                        },
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      const Text('动画', style: TextStyle(fontSize: 13.5)),
                      const SizedBox(width: 14),
                      ChoiceChip(
                        label: const Text('滑动'),
                        selected: ReaderSettings.pageAnim == 'slide',
                        onSelected: (_) {
                          ReaderSettings.pageAnim = 'slide';
                          refresh();
                        },
                      ),
                      const SizedBox(width: 10),
                      ChoiceChip(
                        label: const Text('卷页'),
                        selected: ReaderSettings.pageAnim == 'curl',
                        onSelected: (_) {
                          ReaderSettings.pageAnim = 'curl';
                          refresh();
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      for (int i = 0; i < kReaderThemes.length; i++)
                        Padding(
                          padding: const EdgeInsets.only(right: 14),
                          child: GestureDetector(
                            onTap: () {
                              ReaderSettings.themeIndex = i;
                              refresh();
                            },
                            child: Column(
                              children: [
                                Container(
                                  width: 44,
                                  height: 44,
                                  decoration: BoxDecoration(
                                    color: kReaderThemes[i].bg,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: ReaderSettings.themeIndex == i
                                          ? const Color(0xFFD9A94B)
                                          : const Color(0xFF333D4D),
                                      width: 2,
                                    ),
                                  ),
                                  alignment: Alignment.center,
                                  child: Text(
                                    '羽',
                                    style: TextStyle(
                                      color: kReaderThemes[i].text,
                                      fontSize: 15,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 5),
                                Text(
                                  kReaderThemes[i].name,
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: ReaderSettings.themeIndex == i
                                        ? const Color(0xFFD9A94B)
                                        : const Color(0xFF8B93A1),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = _theme;
    final hasContent = _content.isNotEmpty;

    return Scaffold(
      backgroundColor: theme.bg,
      body: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: _handleTapZone,
              onHorizontalDragEnd:
                  _paged ? null : _handleHorizontalDragEnd,
              child: SafeArea(
                bottom: false,
                child: _paged
                    ? _buildPagedArea(theme)
                    : _initError != null
                    ? _errorView(_initError!, retry: _init)
                    : !hasContent && _loading
                        ? Center(
                            child: CircularProgressIndicator(color: theme.text),
                          )
                        : !hasContent && _error != null
                            ? _errorView(_error!,
                                retry: () => _loadChapter(_index))
                            : SingleChildScrollView(
                                controller: _scroll,
                                padding: EdgeInsets.fromLTRB(
                                    ReaderSettings.pagePadding,
                                    20,
                                    ReaderSettings.pagePadding,
                                    110),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    if (_titles.isNotEmpty)
                                      Text(
                                        _titles[_index],
                                        style: TextStyle(
                                          fontSize:
                                              ReaderSettings.fontSize + 3,
                                          fontWeight: FontWeight.w600,
                                          color: theme.text,
                                          height: 1.5,
                                        ),
                                      ),
                                    const SizedBox(height: 20),
                                    if (_loading)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(top: 40),
                                        child: Center(
                                          child: CircularProgressIndicator(
                                            color: theme.text,
                                          ),
                                        ),
                                      )
                                    else if (_error != null)
                                      _errorView(_error!,
                                          retry: () => _loadChapter(_index))
                                    else
                                      ...(_epubSegments != null
                                          ? _epubWidgets(theme)
                                          : _paragraphs(theme)),
                                  ],
                                ),
                              ),
              ),
            ),
          ),
          // 亮度遮罩（在内容层之上、工具栏之下）
          if (ReaderSettings.screenDim > 0)
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  color: Colors.black.withValues(
                    alpha: ReaderSettings.screenDim,
                  ),
                ),
              ),
            ),
          // 顶栏
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            top: _toolbar ? 0 : -100,
            left: 0,
            right: 0,
            child: Container(
              padding: EdgeInsets.only(
                top: MediaQuery.of(context).padding.top,
              ),
              decoration: const BoxDecoration(
                color: Color(0xE610141B),
              ),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new, size: 19),
                    color: Colors.white,
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Text(
                      widget.book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15.5,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.search, size: 20),
                    color: Colors.white,
                    tooltip: '全本搜索',
                    onPressed: _openSearchSheet,
                  ),
                  IconButton(
                    icon: const Icon(Icons.bookmark_add_outlined, size: 20),
                    color: Colors.white,
                    tooltip: '记录阅读点',
                    onPressed: _addBookmark,
                  ),
                  IconButton(
                    icon: const Icon(Icons.info_outline, size: 20),
                    color: Colors.white,
                    tooltip: '书籍详情',
                    onPressed: _openBookDetail,
                  ),
                  if (_titles.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Text(
                        '${_index + 1} / ${_titles.length}',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // 底栏
          AnimatedPositioned(
            duration: const Duration(milliseconds: 200),
            bottom: _toolbar ? 0 : -160,
            left: 0,
            right: 0,
            child: Container(
              decoration: const BoxDecoration(
                color: Color(0xE610141B),
              ),
              padding: EdgeInsets.fromLTRB(
                18,
                8,
                18,
                14 + MediaQuery.of(context).padding.bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_titles.length > 1)
                    Slider(
                      value: _index.toDouble(),
                      min: 0,
                      max: (_titles.length - 1).toDouble(),
                      onChanged: (v) {
                        final target = v.round();
                        if (target != _index) _loadChapter(target);
                      },
                    ),
                  Row(
                    children: [
                      Expanded(
                        child: _barBtn(
                          Icons.skip_previous,
                          '上一章',
                          _index > 0 ? () => _loadChapter(_index - 1) : null,
                        ),
                      ),
                      Expanded(
                        child: _barBtn(Icons.list_alt, '目录',
                            _titles.isEmpty ? null : _openToc),
                      ),
                      Expanded(
                        child: _barBtn(Icons.settings_outlined, '设置',
                            _showSettings),
                      ),
                      Expanded(
                        child: _barBtn(
                            Icons.bookmarks_outlined, '阅读点', _showBookmarks),
                      ),
                      Expanded(
                        child: _barBtn(
                          _ttsActive
                              ? Icons.stop_circle_outlined
                              : Icons.headset_outlined,
                          '听书',
                          _showTtsSheet,
                        ),
                      ),
                      Expanded(
                        child: _barBtn(
                          Icons.skip_next,
                          '下一章',
                          _index < _titles.length - 1
                              ? () => _loadChapter(_index + 1)
                              : null,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _paragraphs(ReaderTheme theme) {
    final style = ReaderSettings.applyTextStyle(TextStyle(
      fontSize: ReaderSettings.fontSize,
      height: ReaderSettings.lineHeight,
      color: theme.text,
    ));
    return [
      for (final p in _content.split('\n'))
        if (p.trim().isNotEmpty)
          Padding(
            padding: EdgeInsets.only(bottom: ReaderSettings.paragraphGap),
            child: Text(p, style: style),
          ),
    ];
  }

  String get _footerStatus {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    final bat = _batteryLevel >= 0 ? ' · $_batteryLevel%' : '';
    return '$hh:$mm$bat';
  }

  /// epub 章节的图文混排（滚动模式）
  List<Widget> _epubWidgets(ReaderTheme theme) {
    final style = ReaderSettings.applyTextStyle(TextStyle(
      fontSize: ReaderSettings.fontSize,
      height: ReaderSettings.lineHeight,
      color: theme.text,
    ));
    return [
      for (final seg in _epubSegments ?? const <ReaderSegment>[])
        if (seg.isImage)
          _epubImageWidget(seg.image!, theme)
        else
          for (final p in seg.text!.split('\n'))
            if (p.trim().isNotEmpty)
              Padding(
                padding: EdgeInsets.only(bottom: ReaderSettings.paragraphGap),
                child: Text(p, style: style),
              ),
    ];
  }

  Widget _epubImageWidget(String src, ReaderTheme theme) {
    final bytes = _epub?.imageBytes(_epub!.chapters[_index].href, src);
    return Padding(
      padding: EdgeInsets.only(bottom: ReaderSettings.paragraphGap),
      child: bytes == null
          ? _imgFallback(theme)
          : GestureDetector(
              onTap: () => _openImageViewer(bytes),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(bytes, fit: BoxFit.fitWidth),
              ),
            ),
    );
  }

  Widget _epubImagePage(String src, ReaderTheme theme) {
    final bytes = _epub?.imageBytes(_epub!.chapters[_index].href, src);
    return Padding(
      padding: EdgeInsets.symmetric(
          horizontal: ReaderSettings.pagePadding, vertical: 8),
      child: bytes == null
          ? _imgFallback(theme)
          : GestureDetector(
              onTap: () => _openImageViewer(bytes),
              child: Center(child: Image.memory(bytes, fit: BoxFit.contain)),
            ),
    );
  }

  /// 图片全屏查看（可缩放）
  void _openImageViewer(Uint8List bytes) {
    Navigator.push(
      context,
      PageRouteBuilder<void>(
        opaque: true,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) => _ImageViewerPage(bytes: bytes),
      ),
    );
  }

  Widget _imgFallback(ReaderTheme theme) {
    return Container(
      height: 110,
      decoration: BoxDecoration(
        color: theme.text.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.broken_image_outlined,
        color: theme.text.withValues(alpha: 0.35),
        size: 28,
      ),
    );
  }

  Widget _barBtn(IconData icon, String label, VoidCallback? onTap) {
    final disabled = onTap == null;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(
          children: [
            Icon(
              icon,
              size: 21,
              color: disabled
                  ? Colors.white.withValues(alpha: 0.25)
                  : Colors.white,
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: disabled
                    ? Colors.white.withValues(alpha: 0.25)
                    : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _errorView(String msg, {required VoidCallback retry}) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline,
                size: 44, color: _theme.text.withValues(alpha: 0.4)),
            const SizedBox(height: 14),
            Text(
              msg,
              textAlign: TextAlign.center,
              style: TextStyle(color: _theme.text, fontSize: 14, height: 1.6),
            ),
            const SizedBox(height: 18),
            OutlinedButton(
              onPressed: retry,
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 分页模式的页单元：一段文字或一张图片
class _PageUnit {
  final int start;
  final int end;
  final String? image;

  const _PageUnit.text(this.start, this.end) : image = null;
  const _PageUnit.image(this.image, this.start) : end = 0;

  bool get isImage => image != null;
}

/// 图片全屏查看页（双指缩放，点右上角关闭）
class _ImageViewerPage extends StatelessWidget {
  final Uint8List bytes;
  const _ImageViewerPage({required this.bytes});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Center(
            child: InteractiveViewer(
              maxScale: 5,
              child: Image.memory(bytes),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topRight,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
