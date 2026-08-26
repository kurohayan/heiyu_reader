import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';

import '../services/importer.dart';
import '../theme.dart';
import 'search_page.dart';
import 'settings_page.dart';
import 'shelf_page.dart';
import 'sources_page.dart';
import 'wifi_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  int _index = 0;
  StreamSubscription<List<SharedMediaFile>>? _shareSub;

  static const _tabs = [
    ShelfPage(),
    SearchPage(),
    SourcesPage(),
    WifiPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initSharing();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scanInbox());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shareSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _scanInbox();
  }

  /// iOS「用黑羽阅读打开」：系统会把文件放进 Documents/Inbox
  Future<void> _scanInbox() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final inbox = Directory(p.join(docs.path, 'Inbox'));
      if (!await inbox.exists()) return;
      var count = 0;
      await for (final entity in inbox.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path).toLowerCase();
        if (!name.endsWith('.txt') && !name.endsWith('.epub')) continue;
        try {
          await BookImporter.importLocalFile(entity);
          await entity.delete();
          count++;
        } catch (_) {}
      }
      if (count > 0 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已通过「打开方式」导入 $count 本书')),
        );
      }
    } catch (_) {}
  }

  /// Android 分享面板 / 打开方式
  void _initSharing() {
    if (!Platform.isAndroid) return;
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      _importShared(files);
    });
    _shareSub = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_importShared);
  }

  Future<void> _importShared(List<SharedMediaFile> files) async {
    var count = 0;
    for (final f in files) {
      final lower = f.path.toLowerCase();
      if (!lower.endsWith('.txt') && !lower.endsWith('.epub')) continue;
      try {
        await BookImporter.importLocalFile(File(f.path));
        count++;
      } catch (_) {}
    }
    if (count > 0) {
      try {
        await ReceiveSharingIntent.instance.reset();
      } catch (_) {}
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已通过分享导入 $count 本书')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        height: 62,
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.menu_book_outlined),
            selectedIcon: Icon(Icons.menu_book, color: kAccent),
            label: '书架',
          ),
          NavigationDestination(
            icon: const Icon(Icons.travel_explore_outlined),
            selectedIcon: Icon(Icons.travel_explore, color: kAccent),
            label: '搜索',
          ),
          NavigationDestination(
            icon: const Icon(Icons.source_outlined),
            selectedIcon: Icon(Icons.source_rounded, color: kAccent),
            label: '书源',
          ),
          NavigationDestination(
            icon: const Icon(Icons.wifi_outlined),
            selectedIcon: Icon(Icons.wifi, color: kAccent),
            label: '传输',
          ),
          NavigationDestination(
            icon: const Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings, color: kAccent),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
