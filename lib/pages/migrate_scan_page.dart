import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/backup_service.dart';

/// 扫码迁移：扫旧设备出示的迁移码 → 拉取备份 → 本机恢复
class MigrateScanPage extends StatefulWidget {
  const MigrateScanPage({super.key});

  @override
  State<MigrateScanPage> createState() => _MigrateScanPageState();
}

class _MigrateScanPageState extends State<MigrateScanPage> {
  bool _handling = false;
  String? _error;

  Future<void> _handle(String raw) async {
    if (_handling) return;
    final payload = Uri.tryParse(raw);
    if (payload?.scheme != 'heiyu' || payload?.host != 'migrate') return;
    final rawBase = payload?.queryParameters['u'];
    final base = rawBase == null ? null : Uri.tryParse(rawBase);
    if (base == null || (base.scheme != 'http' && base.scheme != 'https')) {
      return;
    }
    setState(() {
      _handling = true;
      _error = null;
    });
    try {
      final backupUri = base.replace(
        path: '/backup',
      );
      final resp = await http.get(backupUri).timeout(
            const Duration(seconds: 60),
          );
      if (resp.statusCode != 200) throw 'HTTP ${resp.statusCode}';
      final summary = await BackupService.restore(resp.bodyBytes);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(summary)));
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _handling = false;
        _error = '迁移失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫码迁移')),
      body: Stack(
        children: [
          MobileScanner(
            onDetect: (capture) {
              for (final b in capture.barcodes) {
                final v = b.rawValue;
                if (v != null) {
                  _handle(v);
                  break;
                }
              }
            },
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 60,
            child: Column(
              children: [
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Color(0xFFE0655A)),
                    ),
                  ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _handling ? '正在拉取备份并恢复…' : '对准旧设备出示的迁移码',
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          if (_handling)
            const Center(
              child: SizedBox(
                width: 42,
                height: 42,
                child: CircularProgressIndicator(),
              ),
            ),
        ],
      ),
    );
  }
}
