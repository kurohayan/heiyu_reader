import 'package:flutter/material.dart';

import '../db/app_database.dart';
import '../services/font_service.dart';
import '../state/app_state.dart';
import '../theme.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final Map<String, double> _dlProgress = {};
  ({int today, int total, int chapters, int streak})? _stats;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  Future<void> _loadStats() async {
    final s = await AppDatabase.instance.readingStats();
    if (mounted) setState(() => _stats = s);
  }

  String _fmtDuration(int seconds) {
    if (seconds < 3600) return '${(seconds / 60).round()} 分钟';
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    return '$h 小时${m > 0 ? ' $m 分' : ''}';
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Widget _statTile(String label, String value) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: kAccent,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11, color: kSubText),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _downloadFont(DownloadableFont font) async {
    setState(() => _dlProgress[font.key] = 0);
    try {
      await FontService.download(
        font.key,
        onProgress: (v) {
          if (mounted) setState(() => _dlProgress[font.key] = v);
        },
      );
      _toast('${font.label} 已可用');
    } catch (e) {
      _toast('下载失败：$e');
    }
    if (mounted) setState(() => _dlProgress.remove(font.key));
  }

  Future<void> _removeFont(DownloadableFont font) async {
    await FontService.remove(font.key);
    setState(() {});
    _toast('已删除 ${font.label}');
  }

  Future<void> _editCustomFont() async {
    final controller =
        TextEditingController(text: ReaderSettings.customFontFamily);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义字体'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: '如 Songti SC、Kaiti SC、PingFang SC',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '填写系统已安装字体的家族名（含你在 iOS 通过描述文件安装的字体），'
              '保存后在阅读器字体里选「自定义」生效。',
              style: TextStyle(fontSize: 12, color: kSubText, height: 1.6),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    ReaderSettings.customFontFamily = controller.text.trim();
    if (ReaderSettings.customFontFamily.isNotEmpty) {
      ReaderSettings.fontKey = 'custom';
    } else if (ReaderSettings.fontKey == 'custom') {
      ReaderSettings.fontKey = 'system';
    }
    await ReaderSettings.save();
    setState(() {});
    _toast('自定义字体已保存');
  }

  Widget _fontRow(DownloadableFont font) {
    final downloaded = FontService.isDownloaded(font.key);
    final downloading = _dlProgress.containsKey(font.key);
    return ListTile(
      leading: Icon(Icons.font_download_outlined, color: kSubText),
      title: Text(font.label),
      subtitle: Text(
        downloading
            ? '下载中 ${(_dlProgress[font.key]! * 100).toStringAsFixed(0)}%'
            : '${font.sizeHint}${downloaded ? ' · 已下载' : ''}',
        style: TextStyle(fontSize: 12, color: kSubText),
      ),
      trailing: downloading
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton(
              onPressed: () =>
                  downloaded ? _removeFont(font) : _downloadFont(font),
              child: Text(downloaded ? '删除' : '下载'),
            ),
    );
  }

  Future<void> _clearCache() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空章节缓存？'),
        content: const Text(
          '将删除所有在线书籍已下载的章节缓存，下次阅读时需重新加载。',
          style: TextStyle(fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Color(0xFFE0655A))),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppDatabase.instance.clearChapterCache();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('缓存已清空')),
      );
    }
  }

  Widget _sectionTitle(String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 22, 16, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color: kAccent,
          fontWeight: FontWeight.w600,
          letterSpacing: 1,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeMode = AppState.appThemeMode.value;
    final accent = AppState.accentKey.value;

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 30),
        children: [
          _sectionTitle('外观'),
          for (final (mode, label, desc) in [
            (AppThemeMode.system, '跟随系统', '自动匹配系统的深浅色'),
            (AppThemeMode.dark, '深色', '暗夜阅读，长时间更护眼'),
            (AppThemeMode.light, '浅色', '日间清爽的纸感界面'),
          ])
            RadioListTile<AppThemeMode>(
              value: mode,
              groupValue: themeMode,
              title: Text(label),
              subtitle: Text(desc,
                  style: TextStyle(fontSize: 12, color: kSubText)),
              onChanged: (v) async {
                await AppState.saveThemeMode(v!);
                setState(() {});
              },
            ),
          _sectionTitle('主题色'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 12,
              children: [
                for (final opt in kAccentOptions)
                  GestureDetector(
                    onTap: () async {
                      await AppState.saveAccent(opt.keyName);
                      setState(() {});
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: opt.dark,
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: accent == opt.keyName
                                  ? kAccent
                                  : Colors.transparent,
                              width: 3,
                            ),
                            boxShadow: [
                              if (accent == opt.keyName)
                                BoxShadow(
                                  color: opt.dark.withValues(alpha: 0.4),
                                  blurRadius: 8,
                                ),
                            ],
                          ),
                          child: accent == opt.keyName
                              ? Icon(
                                  Icons.check,
                                  size: 20,
                                  color: kOnAccent,
                                )
                              : null,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          opt.label,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: accent == opt.keyName ? kAccent : kSubText,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          _sectionTitle('阅读'),
          if (_stats != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Row(
                children: [
                  _statTile('今日', _fmtDuration(_stats!.today)),
                  _statTile('累计', _fmtDuration(_stats!.total)),
                  _statTile('已读', '${_stats!.chapters} 章'),
                  _statTile('连续', '${_stats!.streak} 天'),
                ],
              ),
            ),
          SwitchListTile(
            value: ReaderSettings.pagedMode,
            title: const Text('仿真翻页'),
            subtitle: Text(
              '整页排版 + 左右滑动翻页动画；关闭为滚动阅读',
              style: TextStyle(fontSize: 12, color: kSubText),
            ),
            onChanged: (v) async {
              setState(() => ReaderSettings.pagedMode = v);
              await ReaderSettings.save();
            },
          ),
          _sectionTitle('字体'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              '阅读器里可直接使用系统字体（宋体/楷体/圆体/黑体），'
              '以下字体按需下载，不占安装包体积：',
              style: TextStyle(fontSize: 12, color: kSubText, height: 1.6),
            ),
          ),
          for (final font in kDownloadableFonts) _fontRow(font),
          ListTile(
            leading: Icon(Icons.text_fields, color: kSubText),
            title: const Text('自定义字体'),
            subtitle: Text(
              ReaderSettings.customFontFamily.isEmpty
                  ? '填写系统已安装字体的家族名'
                  : ReaderSettings.customFontFamily,
              style: TextStyle(fontSize: 12, color: kSubText),
            ),
            trailing: TextButton(
              onPressed: _editCustomFont,
              child: const Text('编辑'),
            ),
          ),
          _sectionTitle('数据'),
          ListTile(
            leading: Icon(Icons.cleaning_services_outlined, color: kSubText),
            title: const Text('清空章节缓存'),
            subtitle: Text(
              '删除在线书籍已下载的章节内容',
              style: TextStyle(fontSize: 12, color: kSubText),
            ),
            onTap: _clearCache,
          ),
          _sectionTitle('关于'),
          const ListTile(
            leading: Icon(Icons.menu_book_outlined),
            title: Text('黑羽阅读'),
            subtitle: Text('v1.1.0 · 本地阅读 / WiFi 传书 / 书源订阅'),
          ),
        ],
      ),
    );
  }
}
