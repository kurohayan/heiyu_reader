import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../models/models.dart';
import '../services/importer.dart';
import '../state/app_state.dart';
import '../theme.dart';
import '../widgets/book_cover.dart';
import '../widgets/feather.dart';
import 'reader_page.dart';

class ShelfPage extends StatefulWidget {
  const ShelfPage({super.key});

  @override
  State<ShelfPage> createState() => _ShelfPageState();
}

class _ShelfPageState extends State<ShelfPage> {
  List<Book> _books = [];
  List<ShelfGroup> _shelves = [];
  int _uncategorized = 0;
  int _total = 0;
  int _selected = AppState.lastShelfId; // -1 全部, 0 未分类, >0 自建
  bool _loading = true;

  // 多选管理
  bool _selectMode = false;
  final Set<int> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    AppState.shelfVersion.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    AppState.shelfVersion.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final shelves = await AppDatabase.instance.shelves();
    final uncat = await AppDatabase.instance.uncategorizedCount();
    final all = await AppDatabase.instance.allBooks();
    // 上次选中的书架被删了 → 回退到「全部」
    final valid = _selected == -1 ||
        _selected == 0 ||
        shelves.any((s) => s.id == _selected);
    final sel = valid ? _selected : -1;
    final shown =
        await AppDatabase.instance.allBooks(shelfId: sel == -1 ? null : sel);
    if (!mounted) return;
    setState(() {
      _shelves = shelves;
      _uncategorized = uncat;
      _total = all.length;
      _books = shown;
      _selected = sel;
      _loading = false;
    });
  }

  void _pickShelf(int id) {
    if (_selected == id) return;
    setState(() => _selected = id);
    AppState.saveLastShelf(id);
    _reloadBooksOnly();
  }

  Future<void> _reloadBooksOnly() async {
    final shown = await AppDatabase.instance
        .allBooks(shelfId: _selected == -1 ? null : _selected);
    if (!mounted) return;
    setState(() => _books = shown);
  }

  // ---------- 书架分组管理 ----------

  Future<void> _createShelfDialog() async {
    final controller = TextEditingController();
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('新建书架'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: controller,
                autofocus: true,
                maxLength: 12,
                decoration: InputDecoration(
                  hintText: '书架名称',
                  isDense: true,
                  errorText: error,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  setDlg(() => error = '名称不能为空');
                  return;
                }
                final dup = name == '全部' ||
                    name == '未分类' ||
                    _shelves.any((s) => s.name == name);
                if (dup) {
                  setDlg(() => error = '已存在同名书架');
                  return;
                }
                try {
                  final group = await AppDatabase.instance.createShelf(name);
                  if (ctx.mounted) {
                    Navigator.pop(ctx, true);
                    setState(() => _selected = group.id ?? -1);
                    AppState.saveLastShelf(group.id ?? -1);
                  }
                } catch (e) {
                  setDlg(() => error = '$e');
                }
              },
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) _reload();
  }

  Future<void> _manageShelf(ShelfGroup group) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      group.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    '${group.bookCount} 本',
                    style: TextStyle(fontSize: 12, color: kSubText),
                  ),
                ],
              ),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('重命名'),
              onTap: () async {
                Navigator.pop(ctx);
                await _renameShelfDialog(group);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  color: Color(0xFFE0655A)),
              title: const Text('删除书架',
                  style: TextStyle(color: Color(0xFFE0655A))),
              subtitle: group.bookCount > 0
                  ? Text('${group.bookCount} 本书将移入「未分类」',
                      style: const TextStyle(fontSize: 11.5))
                  : null,
              onTap: () async {
                Navigator.pop(ctx);
                await _confirmDeleteShelf(group);
              },
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  Future<void> _renameShelfDialog(ShelfGroup group) async {
    final controller = TextEditingController(text: group.name);
    String? error;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: const Text('重命名书架'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 12,
            decoration: InputDecoration(
              isDense: true,
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  setDlg(() => error = '名称不能为空');
                  return;
                }
                final dup = name == '全部' ||
                    name == '未分类' ||
                    _shelves.any((s) => s.name == name && s.id != group.id);
                if (dup) {
                  setDlg(() => error = '已存在同名书架');
                  return;
                }
                try {
                  await AppDatabase.instance.renameShelf(group.id!, name);
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (e) {
                  setDlg(() => error = '$e');
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) _reload();
  }

  Future<void> _confirmDeleteShelf(ShelfGroup group) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除书架「${group.name}」？'),
        content: Text(
          group.bookCount > 0
              ? '该书架中的 ${group.bookCount} 本书将移入「未分类」。'
              : '空书架将被删除。',
          style: TextStyle(color: kSubText, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFE0655A))),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppDatabase.instance.deleteShelf(group.id!);
    if (_selected == group.id) {
      _selected = -1;
      AppState.saveLastShelf(-1);
    }
    _reload();
  }

  // ---------- 书籍操作 ----------

  Future<void> _bookActions(Book book) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_move_outline),
              title: const Text('移动到书架'),
              onTap: () async {
                Navigator.pop(ctx);
                await _moveBookSheet(book);
              },
            ),
            ListTile(
              leading: const Icon(Icons.checklist_outlined),
              title: const Text('多选管理'),
              onTap: () {
                Navigator.pop(ctx);
                setState(() {
                  _selectMode = true;
                  if (book.id != null) _selectedIds.add(book.id!);
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  color: Color(0xFFE0655A)),
              title: const Text('删除本书',
                  style: TextStyle(color: Color(0xFFE0655A))),
              onTap: () async {
                Navigator.pop(ctx);
                await _confirmDelete(book);
              },
            ),
            const SizedBox(height: 8),
          ],
        );
      },
    );
  }

  // ---------- 多选批量操作 ----------

  void _toggleSelect(Book book) {
    if (book.id == null) return;
    setState(() {
      if (_selectedIds.contains(book.id)) {
        _selectedIds.remove(book.id);
      } else {
        _selectedIds.add(book.id!);
      }
    });
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedIds.clear();
    });
  }

  void _toggleSelectAll() {
    setState(() {
      if (_selectedIds.length == _books.length) {
        _selectedIds.clear();
      } else {
        _selectedIds
          ..clear()
          ..addAll([for (final b in _books) if (b.id != null) b.id!]);
      }
    });
  }

  Future<void> _batchMove() async {
    if (_selectedIds.isEmpty) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final options = [
          (id: 0, name: '未分类'),
          ..._shelves.map((s) => (id: s.id ?? -2, name: s.name)),
        ];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Text(
                  '移动 ${_selectedIds.length} 本到书架',
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              for (final o in options)
                ListTile(
                  title: Text(o.name),
                  onTap: () async {
                    Navigator.pop(ctx);
                    for (final id in _selectedIds) {
                      await AppDatabase.instance.moveBook(id, o.id);
                    }
                    AppState.notifyShelf();
                    _exitSelectMode();
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _batchDelete() async {
    if (_selectedIds.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除选中的 ${_selectedIds.length} 本书？'),
        content: Text(
          '本地书将同时删除文件，在线书将清除缓存章节。',
          style: TextStyle(color: kSubText, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFE0655A))),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final all = await AppDatabase.instance.allBooks();
    for (final b in all) {
      if (b.id != null && _selectedIds.contains(b.id)) {
        await BookImporter.deleteBookFiles(b);
        await AppDatabase.instance.deleteBook(b.id!);
      }
    }
    AppState.notifyShelf();
    _exitSelectMode();
  }

  Widget? get _selectBottomBar {
    if (!_selectMode) return null;
    final all = _selectedIds.length == _books.length && _books.isNotEmpty;
    return Container(
      decoration: BoxDecoration(
        color: kSurface,
        border: Border(top: BorderSide(color: kDivider, width: 0.6)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Text(
                    '已选 ${_selectedIds.length} 本',
                    style: const TextStyle(fontSize: 13.5),
                  ),
                ),
              ),
              TextButton(
                onPressed: _toggleSelectAll,
                child: Text(all ? '全不选' : '全选'),
              ),
              TextButton(
                onPressed: _selectedIds.isEmpty ? null : _batchMove,
                child: const Text('移动'),
              ),
              TextButton(
                onPressed: _selectedIds.isEmpty ? null : _batchDelete,
                child: const Text(
                  '删除',
                  style: TextStyle(color: Color(0xFFE0655A)),
                ),
              ),
              TextButton(
                onPressed: _exitSelectMode,
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _moveBookSheet(Book book) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final options = [
          (id: 0, name: '未分类'),
          ..._shelves.map((s) => (id: s.id ?? -2, name: s.name)),
        ];
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Text(
                  '移动到书架',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              for (final o in options)
                ListTile(
                  leading: Icon(
                    book.shelfId == o.id
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: book.shelfId == o.id ? kAccent : kSubText,
                  ),
                  title: Text(o.name),
                  onTap: () async {
                    Navigator.pop(ctx);
                    if (book.id == null || o.id == book.shelfId) return;
                    await AppDatabase.instance.moveBook(book.id!, o.id);
                    AppState.notifyShelf();
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  Future<void> _confirmDelete(Book book) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除《${book.title}》？'),
        content: Text(
          book.isLocal ? '将同时删除本地文件与阅读进度。' : '将移除书架条目与已缓存章节。',
          style: TextStyle(color: kSubText, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Color(0xFFE0655A))),
          ),
        ],
      ),
    );
    if (ok != true || book.id == null) return;
    await BookImporter.deleteBookFiles(book);
    await AppDatabase.instance.deleteBook(book.id!);
    AppState.notifyShelf();
  }

  // ---------- 页面 ----------

  void _open(Book book) async {
    if (_selectMode) {
      _toggleSelect(book);
      return;
    }
    if (book.isLocal && book.path != null) {
      final file = await BookImporter.resolveFile(book.path!);
      if (!await file.exists()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('本地文件不存在，可在「传输」页重新导入')),
          );
        }
        return;
      }
    }
    if (!mounted) return;
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => ReaderPage(book: book)),
    );
  }

  /// 从「文件」App 选择 TXT/EPUB 导入
  Future<void> _importFiles() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'epub'],
        allowMultiple: true,
      );
      if (result == null) return;
      var count = 0;
      for (final path in result.paths) {
        if (path == null) continue;
        try {
          await BookImporter.importLocalFile(File(path));
          count++;
        } catch (_) {}
      }
      if (mounted && count > 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入 $count 本书')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败：$e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            FeatherIcon(size: 22),
            SizedBox(width: 10),
            Text('黑羽阅读'),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_open_outlined, size: 21),
            tooltip: '导入书籍',
            onPressed: _importFiles,
          ),
          IconButton(
            icon: const Icon(Icons.info_outline, size: 21),
            onPressed: () {
              showAboutDialog(
                context: context,
                applicationName: '黑羽阅读',
                applicationVersion: '1.0.0',
                applicationIcon: const FeatherIcon(size: 40),
                children: [
                  SizedBox(
                    width: 260,
                    child: Text(
                      '本地阅读 · WiFi 传书 · 书源订阅 · 多源搜索\n'
                      '支持 TXT / EPUB 格式，书源规则兼容「阅读」格式子集。',
                      style: TextStyle(color: kSubText, fontSize: 13, height: 1.7),
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(
        children: [
          _shelfBar(),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _books.isEmpty
                    ? _empty()
                    : _grid(),
          ),
        ],
      ),
      bottomNavigationBar: _selectBottomBar,
    );
  }

  Widget _shelfBar() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        children: [
          _shelfChip(-1, '全部（$_total）'),
          _shelfChip(0, '未分类（$_uncategorized）'),
          for (final s in _shelves)
            GestureDetector(
              onLongPress: () => _manageShelf(s),
              child: _shelfChip(s.id ?? -2, s.name),
            ),
          ActionChip(
            avatar: Icon(Icons.add, size: 16, color: kAccent),
            label: const Text('新建'),
            labelStyle: TextStyle(color: kAccent, fontSize: 12.5),
            backgroundColor: kCard,
            side: BorderSide(color: kAccent.withValues(alpha: 0.4)),
            onPressed: _createShelfDialog,
          ),
        ],
      ),
    );
  }

  Widget _shelfChip(int id, String label) {
    final selected = _selected == id;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 12.5)),
        selected: selected,
        onSelected: (_) => _pickShelf(id),
        selectedColor: kAccent.withValues(alpha: 0.18),
        labelStyle: TextStyle(color: selected ? kAccent : null),
        side: BorderSide(
          color: selected ? kAccent.withValues(alpha: 0.5) : kDivider,
        ),
      ),
    );
  }

  Widget _empty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FeatherIcon(size: 96, color: kAccent.withValues(alpha: 0.35)),
          const SizedBox(height: 22),
          Text(
            _selected == -1 ? '书架空空如也' : '这个书架还没有书',
            style: const TextStyle(fontSize: 17, color: Color(0xFFC7CDD6)),
          ),
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 48),
            child: Text(
              '在「传输」页通过 WiFi 导入本地书籍\n或在「搜索」页订阅书源后查找小说',
              textAlign: TextAlign.center,
              style: TextStyle(color: kSubText, fontSize: 13, height: 1.9),
            ),
          ),
        ],
      ),
    );
  }

  Widget _grid() {
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 18,
        crossAxisSpacing: 14,
        childAspectRatio: 0.56,
      ),
      itemCount: _books.length,
      itemBuilder: (context, i) {
        final book = _books[i];
        return GestureDetector(
          onTap: () => _open(book),
          onLongPress: () => _bookActions(book),
          child: Column(
            children: [
              Expanded(
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    BookCoverView(book: book),
                    if (book.isOnline)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '在线',
                            style: TextStyle(fontSize: 9, color: kAccent),
                          ),
                        ),
                      ),
                    if (_selectMode)
                      Positioned.fill(
                        child: Container(
                          decoration: BoxDecoration(
                            color: _selectedIds.contains(book.id)
                                ? kAccent.withValues(alpha: 0.18)
                                : Colors.black.withValues(alpha: 0.25),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          alignment: Alignment.center,
                          child: Icon(
                            _selectedIds.contains(book.id)
                                ? Icons.check_circle
                                : Icons.radio_button_unchecked,
                            color: _selectedIds.contains(book.id)
                                ? kAccent
                                : Colors.white70,
                            size: 30,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 7),
              Text(
                book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5),
              ),
              const SizedBox(height: 2),
              Text(
                book.author.isNotEmpty ? book.author : '—',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: kSubText),
              ),
            ],
          ),
        );
      },
    );
  }
}
