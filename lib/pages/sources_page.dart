import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../db/app_database.dart';
import '../engine/source_engine.dart';
import '../models/models.dart';
import '../theme.dart';

class SourcesPage extends StatefulWidget {
  const SourcesPage({super.key});

  @override
  State<SourcesPage> createState() => _SourcesPageState();
}

class _SourcesPageState extends State<SourcesPage> {
  List<BookSource> _sources = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final list = await AppDatabase.instance.allSources();
    if (!mounted) return;
    setState(() {
      _sources = list;
      _loading = false;
    });
  }

  Future<void> _showAddDialog() async {
    final controller = TextEditingController();
    var busy = false;

    Future<void> importRaw(String raw) async {
      try {
        final list = SourceEngine.parseSourcesBody(raw);
        if (list.isEmpty) {
          _toast('未解析到有效书源');
          return;
        }
        int count = 0;
        for (final e in list) {
          final name = (e['bookSourceName'] as String?) ?? '';
          final url = (e['bookSourceUrl'] as String?) ?? '';
          if (name.isEmpty || url.isEmpty) continue;
          await AppDatabase.instance.upsertSource(BookSource(
            name: name.trim(),
            url: url.trim(),
            json: jsonEncode(e),
          ));
          count++;
        }
        _toast('成功导入 $count 个书源');
        _reload();
      } catch (e) {
        _toast('解析失败：$e');
      }
    }

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('添加书源'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  decoration: const InputDecoration(
                    hintText: '书源订阅 URL（http/https）',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '支持「阅读」app 书源格式的订阅地址，也支持直接粘贴书源 JSON。',
                  style: TextStyle(color: kSubText, fontSize: 12, height: 1.6),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                final data = await Clipboard.getData('text/plain');
                if (!ctx.mounted) return;
                final text = data?.text?.trim() ?? '';
                if (text.isEmpty) {
                  _toast('剪贴板为空');
                  return;
                }
                Navigator.pop(ctx);
                if (text.startsWith('http://') || text.startsWith('https://')) {
                  controller.text = text;
                  _showAddDialog();
                  return;
                }
                importRaw(text);
              },
              child: const Text('从剪贴板'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      final url = controller.text.trim();
                      if (url.isEmpty) {
                        _toast('请输入订阅地址');
                        return;
                      }
                      if (!url.startsWith('http')) {
                        // 当作 JSON 处理
                        Navigator.pop(ctx);
                        importRaw(url);
                        return;
                      }
                      setDialogState(() => busy = true);
                      try {
                        final body = await SourceEngine.fetch(url);
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx);
                        importRaw(body);
                      } catch (e) {
                        setDialogState(() => busy = false);
                        _toast('获取失败：$e');
                      }
                    },
              child: busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('导入'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BookSource src) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('删除书源「${src.name}」？'),
        content: Text(
          '删除后，通过该书源加入书架的在线书籍将无法抓取内容。',
          style: TextStyle(color: kSubText, fontSize: 13.5),
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
    if (ok != true || src.id == null) return;
    await AppDatabase.instance.deleteSource(src.id!);
    _reload();
  }

  /// 书源的分组名（bookSourceGroup，空为「未分组」）
  String _groupOf(BookSource src) {
    try {
      final m = jsonDecode(src.json);
      final g = (m is Map ? m['bookSourceGroup'] : null);
      final s = '$g'.trim();
      return s.isEmpty || s == 'null' ? '未分组' : s;
    } catch (_) {
      return '未分组';
    }
  }

  Future<void> _setGroupEnabled(String group, bool enabled) async {
    for (final src in _sources) {
      if (_groupOf(src) == group && src.id != null) {
        await AppDatabase.instance.setSourceEnabled(src.id!, enabled);
      }
    }
    _reload();
  }

  Future<void> _showGroupSheet() async {
    final groups = <String, int>{};
    for (final src in _sources) {
      final g = _groupOf(src);
      groups[g] = (groups[g] ?? 0) + 1;
    }
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: kSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 14, 20, 6),
                child: Text(
                  '分组管理',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              for (final e in groups.entries)
                ListTile(
                  dense: true,
                  title: Text(
                    e.key,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${e.value} 个书源',
                    style: TextStyle(fontSize: 11.5, color: kSubText),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _setGroupEnabled(e.key, true);
                        },
                        child: const Text('启用'),
                      ),
                      TextButton(
                        onPressed: () {
                          Navigator.pop(ctx);
                          _setGroupEnabled(e.key, false);
                        },
                        child: const Text('停用'),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('书源'),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_shared_outlined),
            tooltip: '分组管理',
            onPressed: _sources.isEmpty ? null : _showGroupSheet,
          ),
          IconButton(
            icon: const Icon(Icons.add_circle_outline),
            tooltip: '添加书源',
            onPressed: _showAddDialog,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _sources.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.source_outlined,
                            size: 56, color: kAccent.withValues(alpha: 0.3)),
                        const SizedBox(height: 16),
                        const Text(
                          '还没有书源',
                          style: TextStyle(fontSize: 16),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '点击右上角 ＋ 添加书源订阅地址\n书源用于搜索网络小说与在线阅读',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: kSubText,
                            fontSize: 13,
                            height: 1.8,
                          ),
                        ),
                      ],
                    ),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _sources.length,
                  separatorBuilder: (_, __) =>
                      const Divider(height: 1, indent: 16, endIndent: 16),
                  itemBuilder: (context, i) {
                    final src = _sources[i];
                    return ListTile(
                      leading: Icon(
                        src.enabled
                            ? Icons.check_circle
                            : Icons.radio_button_unchecked,
                        color: src.enabled ? kAccent : kSubText,
                        size: 20,
                      ),
                      title: Text(
                        src.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        src.url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: kSubText),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () => _confirmDelete(src),
                      ),
                      onTap: () async {
                        if (src.id == null) return;
                        src.enabled = !src.enabled;
                        await AppDatabase.instance
                            .setSourceEnabled(src.id!, src.enabled);
                        _reload();
                      },
                    );
                  },
                ),
    );
  }
}
