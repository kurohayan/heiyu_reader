import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/wifi_server.dart';
import '../theme.dart';
import 'migrate_scan_page.dart';

class WifiPage extends StatefulWidget {
  const WifiPage({super.key});

  @override
  State<WifiPage> createState() => _WifiPageState();
}

class _WifiPageState extends State<WifiPage> {
  final WifiServer _server = WifiServer.instance;
  bool _busy = false;
  final List<String> _events = [];

  @override
  void initState() {
    super.initState();
    _server.onImported = (title) {
      if (!mounted) return;
      setState(() {
        _events.insert(0, '《$title》已导入书架');
        if (_events.length > 30) _events.removeLast();
      });
    };
  }

  Future<void> _toggle() async {
    setState(() => _busy = true);
    try {
      if (_server.running) {
        await _server.stop();
      } else {
        await _server.start();
      }
      setState(() {});
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('启动失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 旧设备：出示迁移码（含本机服务地址）
  Future<void> _showMigrateQr() async {
    if (!_server.running) await _toggle();
    if (!_server.running || !mounted) return;
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('迁移码'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: 'heiyu://migrate?u=${Uri.encodeComponent(_server.url)}',
                size: 200,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _server.url,
              style: TextStyle(fontSize: 13, color: kAccent),
            ),
            const SizedBox(height: 8),
            Text(
              '保持两台设备在同一 WiFi 下\n新机在「传输」页点「扫码迁移」',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: kSubText, height: 1.7),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  /// 新设备：扫码迁移
  Future<void> _scanMigrate() async {
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (_) => const MigrateScanPage()),
    );
    if (ok == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('迁移完成')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _server.running;
    return Scaffold(
      appBar: AppBar(title: const Text('WiFi 传书')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              children: [
                Text(
                  running ? '服务已开启' : '服务未开启',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: running ? const Color(0xFF6FCE7F) : kSubText,
                  ),
                ),
                const SizedBox(height: 14),
                if (running) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: QrImageView(
                      data: _server.url,
                      size: 180,
                      backgroundColor: Colors.white,
                      eyeStyle: const QrEyeStyle(
                        eyeShape: QrEyeShape.square,
                        color: Colors.black,
                      ),
                      dataModuleStyle: const QrDataModuleStyle(
                        dataModuleShape: QrDataModuleShape.square,
                        color: Colors.black,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    _server.url,
                    style: TextStyle(
                      fontSize: 18,
                      color: kAccent,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '确保电脑与手机连接同一 WiFi\n在电脑浏览器输入上方地址，或扫描二维码上传',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: kSubText,
                      fontSize: 12.5,
                      height: 1.8,
                    ),
                  ),
                ] else ...[
                  const SizedBox(height: 6),
                  Text(
                    '点击下方按钮启动传输服务\n支持批量上传 TXT / EPUB 文件',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: kSubText,
                      fontSize: 13,
                      height: 1.9,
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 46,
                  child: FilledButton.icon(
                    onPressed: _busy ? null : _toggle,
                    icon:
                        Icon(running ? Icons.stop_circle_outlined : Icons.wifi),
                    label: Text(
                      _busy ? '请稍候…' : (running ? '停止传输' : '启动传输'),
                      style: const TextStyle(fontSize: 15),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor:
                          running ? const Color(0xFF3A4356) : kAccent,
                      foregroundColor:
                          running ? Colors.white : const Color(0xFF241A06),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '设备迁移',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  '书架、书源、阅读点、设置与本地书整体搬家到另一台设备。'
                  '也可以在电脑网页里下载/上传备份包。',
                  style:
                      TextStyle(fontSize: 12.5, color: kSubText, height: 1.7),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _showMigrateQr,
                        icon: const Icon(Icons.qr_code, size: 18),
                        label: const Text('出示迁移码'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size(0, 40),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _scanMigrate,
                        icon: const Icon(Icons.qr_code_scanner, size: 18),
                        label: const Text('扫码迁移'),
                        style: FilledButton.styleFrom(
                          backgroundColor: kAccent,
                          foregroundColor: kOnAccent,
                          minimumSize: const Size(0, 40),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (_events.isNotEmpty) ...[
            const SizedBox(height: 22),
            Text(
              '最近导入',
              style: TextStyle(fontSize: 14, color: kSubText),
            ),
            const SizedBox(height: 8),
            ..._events.map(
              (e) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle,
                        size: 16, color: Color(0xFF6FCE7F)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        e,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 13.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
