import 'dart:io';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/importer.dart';

const List<List<Color>> _coverGradients = [
  [Color(0xFF2A3346), Color(0xFF151B26)],
  [Color(0xFF3A2E46), Color(0xFF191322)],
  [Color(0xFF23403A), Color(0xFF101D1A)],
  [Color(0xFF463A2A), Color(0xFF201812)],
  [Color(0xFF462A30), Color(0xFF1F1214)],
  [Color(0xFF2A4146), Color(0xFF121D20)],
];

/// 书籍封面：本地文件 / 网络图 / 渐变兜底
class BookCoverView extends StatelessWidget {
  final Book book;
  final double radius;
  const BookCoverView({super.key, required this.book, this.radius = 8});

  static final Map<String, Future<File?>> _coverFutures = {};

  /// 解析封面路径（相对路径/历史绝对路径兼容，结果带缓存）
  static Future<File?> _resolveCover(String stored) {
    return _coverFutures.putIfAbsent(stored, () async {
      final f = await BookImporter.resolveFile(stored);
      return await f.exists() ? f : null;
    });
  }

  int get _hash {
    int h = 7;
    for (final c in book.title.codeUnits) {
      h = (h * 31 + c) & 0x7fffffff;
    }
    return h;
  }

  Widget _fallback(BuildContext context) {
    final g = _coverGradients[_hash % _coverGradients.length];
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: g,
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            book.title,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Color(0xFFE8E4DA),
              fontSize: 14,
              fontWeight: FontWeight.w600,
              height: 1.5,
            ),
          ),
          if (book.author.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              book.author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: const Color(0xFFE8E4DA).withValues(alpha: 0.55),
                fontSize: 10,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _clip(Widget child) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget content;
    if (book.coverPath != null) {
      content = FutureBuilder<File?>(
        future: _resolveCover(book.coverPath!),
        builder: (context, snap) {
          final f = snap.data;
          if (f == null) return _fallback(context);
          return Image.file(
            f,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _fallback(context),
          );
        },
      );
    } else if (book.coverUrl != null && book.coverUrl!.isNotEmpty) {
      content = Image.network(
        book.coverUrl!,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _fallback(context),
      );
    } else {
      content = _fallback(context);
    }

    return _clip(
      DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xFF1A212C),
          borderRadius: BorderRadius.circular(radius),
        ),
        child: content,
      ),
    );
  }
}
