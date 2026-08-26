import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import '../models/models.dart';
import '../services/font_service.dart';
import '../services/importer.dart';
import '../state/app_state.dart';

/// A backup archive contains an unsupported or unsafe structure.
class BackupArchiveValidationException implements Exception {
  final String message;

  const BackupArchiveValidationException(this.message);

  @override
  String toString() => message;
}

/// 备份/恢复：书架数据 + 书源 + 阅读点 + 阅读设置 + 本地书文件（zip）
class BackupService {
  static const manifestName = 'heiyu_backup.json';

  /// Resolve an online book's source id against the ids created while
  /// restoring its source records. A missing mapping intentionally becomes
  /// null instead of retaining an id from the source device's database.
  static int? remapSourceId(int? oldSourceId, Map<int, int> sourceIdMap) {
    if (oldSourceId == null) return null;
    return sourceIdMap[oldSourceId];
  }

  /// 需要随备份携带的 SharedPreferences 键
  static const _prefKeys = [
    'reader_font_size',
    'reader_line_height',
    'reader_theme',
    'reader_para_gap',
    'reader_paged_mode',
    'reader_letter_spacing',
    'reader_page_padding',
    'reader_font_key',
    'reader_custom_font',
    'reader_screen_dim',
    'last_shelf_id',
    'app_theme_mode',
    'app_accent',
  ];

  /// 打包备份为 zip 字节
  static Future<Uint8List> buildBackup() async {
    final db = AppDatabase.instance;
    final sp = await SharedPreferences.getInstance();

    final books = await db.allBooks();
    final shelves = await db.shelves();
    final bookmarks = await db.allBookmarks();
    final sources = await db.allSources();

    final prefs = <String, Object?>{};
    for (final k in _prefKeys) {
      if (sp.containsKey(k)) prefs[k] = sp.get(k);
    }

    final manifest = {
      'app': 'heiyu_reader',
      'version': 1,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
      'books': [for (final b in books) b.toMap()],
      'shelves': [
        for (final s in shelves) {'id': s.id, 'name': s.name}
      ],
      'bookmarks': [for (final b in bookmarks) b.toMap()],
      'sources': [for (final s in sources) s.toMap()],
      'prefs': prefs,
    };

    final archive = Archive();
    final manifestBytes = utf8.encode(jsonEncode(manifest));
    archive.addFile(
        ArchiveFile(manifestName, manifestBytes.length, manifestBytes));

    final docs = await BookImporter.docsDir();
    for (final sub in ['books', 'covers', 'fonts']) {
      final dir = Directory(p.join(docs.path, sub));
      if (!await dir.exists()) continue;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final bytes = await entity.readAsBytes();
        archive.addFile(
          ArchiveFile('$sub/${p.basename(entity.path)}', bytes.length, bytes),
        );
      }
    }

    final encoded = ZipEncoder().encode(archive);
    return Uint8List.fromList(encoded ?? const []);
  }

  /// 从 zip 字节恢复（合并模式：按唯一键去重，不覆盖已有书籍）
  /// 返回恢复摘要文本
  static Future<String> restore(Uint8List zipBytes) async {
    // Inspect structure before decoding while deliberately imposing no size
    // limit on user-created backup packages.
    final directory = ZipDirectory.read(InputStream(zipBytes));
    _validateZipDirectory(directory);

    final archive = ZipDecoder().decodeBytes(zipBytes);
    validateRestoreArchiveFiles(archive.files);
    ArchiveFile? manifestFile;
    for (final f in archive.files) {
      if (f.name == manifestName) {
        manifestFile = f;
        break;
      }
    }
    if (manifestFile == null) throw '不是有效的黑羽阅读备份包';

    final manifest = jsonDecode(utf8.decode(manifestFile.content as List<int>))
        as Map<String, dynamic>;
    if (manifest['app'] != 'heiyu_reader') throw '不是有效的黑羽阅读备份包';

    final docs = await BookImporter.docsDir();

    // 1. 写入文件（books/covers/fonts）
    int fileCount = 0;
    for (final f in archive.files) {
      if (!f.isFile) continue;
      if (f.isSymbolicLink) {
        throw const BackupArchiveValidationException('备份包含不支持的符号链接');
      }
      final content = f.content as List<int>;

      final parts = f.name.split('/');
      if (parts.length == 2) {
        final sub = parts[0];
        if (sub == 'books' || sub == 'covers' || sub == 'fonts') {
          final dir = Directory(p.join(docs.path, sub));
          if (!await dir.exists()) await dir.create(recursive: true);
          final target = File(p.join(dir.path, parts[1]));
          await target.writeAsBytes(content);
          fileCount++;
        }
      }
      f.clear();
    }

    final db = AppDatabase.instance;

    // 2. 书架：按名称去重建，映射旧 id → 新 id
    final shelfIdMap = <int, int>{};
    final existingShelves = await db.shelves();
    final rawShelves = (manifest['shelves'] as List? ?? const []);
    for (final raw in rawShelves) {
      final m = Map<String, dynamic>.from(raw as Map);
      final name = (m['name'] as String? ?? '').trim();
      final oldId = (m['id'] as int?) ?? 0;
      if (name.isEmpty) continue;
      var newId = existingShelves
          .firstWhere((s) => s.name == name,
              orElse: () => ShelfGroup(id: null, name: ''))
          .id;
      newId ??= (await db.createShelf(name)).id;
      shelfIdMap[oldId] = newId!;
    }

    // 3. 书源：必须先恢复并记录旧 id → 当前数据库 id，不能把备份
    //    中的旧 id 直接写入在线书。
    int newSources = 0;
    final sourceIdMap = <int, int>{};
    final existingSources = await db.allSources();
    final rawSources = (manifest['sources'] as List? ?? const []);
    for (final raw in rawSources) {
      final m = Map<String, dynamic>.from(raw as Map);
      final oldId = _asInt(m['id']);
      m.remove('id');
      final src = BookSource.fromMap(m);
      if (src.url.isEmpty) continue;

      BookSource? persisted;
      for (final existing in existingSources) {
        if (existing.url == src.url) {
          persisted = existing;
          break;
        }
      }
      if (persisted == null) {
        persisted = await db.upsertSource(src);
        // upsertSource returns the id assigned by SQLite. Keep the in-memory
        // list aligned with that result for duplicate URLs in one manifest.
        existingSources.removeWhere((e) => e.url == persisted!.url);
        existingSources.add(persisted);
        newSources++;
      }
      final newId = persisted.id;
      if (oldId != null && newId != null) sourceIdMap[oldId] = newId;
    }

    // 4. 书籍：本地书按 path、在线书按 origin 去重
    final existingBooks = await db.allBooks();
    final rawBooks = (manifest['books'] as List? ?? const []);
    final bookIdMap = <int, int>{};
    int newBooks = 0;
    for (final raw in rawBooks) {
      final m = Map<String, dynamic>.from(raw as Map);
      final oldId = _asInt(m['id']) ?? 0;
      m.remove('id');
      final book = Book.fromMap(m);
      book.shelfId = shelfIdMap[book.shelfId] ?? 0;
      if (book.isOnline) {
        book.sourceId = remapSourceId(book.sourceId, sourceIdMap);
      }

      Book? existing;
      for (final e in existingBooks) {
        if (book.isLocal && e.isLocal && e.path == book.path) {
          existing = e;
          break;
        }
        if (book.isOnline && e.isOnline && e.origin == book.origin) {
          existing = e;
          break;
        }
      }
      if (existing != null) {
        bookIdMap[oldId] = existing.id!;
      } else {
        await db.insertBook(book);
        existingBooks.add(book);
        bookIdMap[oldId] = book.id!;
        newBooks++;
      }
    }

    // 5. 阅读点：按 书+章节+位置 去重追加
    int newBookmarks = 0;
    final rawBookmarks = (manifest['bookmarks'] as List? ?? const []);
    final existingBookmarks = await db.allBookmarks();
    for (final raw in rawBookmarks) {
      final m = Map<String, dynamic>.from(raw as Map);
      final oldBookId = (m['book_id'] as int?) ?? 0;
      final newBookId = bookIdMap[oldBookId];
      if (newBookId == null) continue;
      final chapter = (m['chapter'] as int?) ?? 0;
      final dup = existingBookmarks.any(
        (b) => b.bookId == newBookId && b.chapter == chapter,
      );
      if (dup) continue;
      await db.addBookmark(ReadingBookmark(
        bookId: newBookId,
        chapter: chapter,
        offset: ((m['offset'] as num?) ?? 0).toDouble(),
        label: (m['label'] as String?) ?? '',
        createdAt:
            (m['created_at'] as int?) ?? DateTime.now().millisecondsSinceEpoch,
      ));
      newBookmarks++;
    }

    // 6. 偏好设置
    final prefs = manifest['prefs'];
    if (prefs is Map) {
      final sp = await SharedPreferences.getInstance();
      for (final entry in prefs.entries) {
        final v = entry.value;
        if (v is bool) await sp.setBool(entry.key, v);
        if (v is int) await sp.setInt(entry.key, v);
        if (v is double) await sp.setDouble(entry.key, v);
        if (v is String) await sp.setString(entry.key, v);
      }
    }

    await AppState.loadPrefs();
    await ReaderSettings.load();
    await FontService.init();
    AppState.notifyShelf();

    return '恢复完成：新增 $newBooks 本书、$newBookmarks 个阅读点、'
        '$newSources 个书源，写入 $fileCount 个文件';
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// Validates decoded entries without restricting backup size.
  static void validateRestoreArchiveFiles(Iterable<ArchiveFile> files) {
    for (final file in files) {
      _validateEntryName(file.name);
      if (file.isSymbolicLink) {
        throw const BackupArchiveValidationException('备份包含不支持的符号链接');
      }
    }
  }

  static void _validateZipDirectory(ZipDirectory directory) {
    for (final header in directory.fileHeaders) {
      final encrypted = (header.generalPurposeBitFlag & 0x1) != 0 ||
          header.compressionMethod == ZipFile.zipCompressionAexEncryption;
      if (encrypted) {
        throw const BackupArchiveValidationException('不支持加密备份');
      }

      const supportedMethods = {
        ZipFile.zipCompressionStore,
        ZipFile.zipCompressionDeflate,
        ZipFile.zipCompressionBZip2,
      };
      if (!supportedMethods.contains(header.compressionMethod)) {
        throw BackupArchiveValidationException(
          '备份包含不支持的压缩方式：${header.compressionMethod}',
        );
      }

      final size = header.uncompressedSize;
      final compressedSize = header.compressedSize;
      if (size == null ||
          compressedSize == null ||
          size < 0 ||
          compressedSize < 0) {
        throw const BackupArchiveValidationException('备份条目大小异常');
      }
      _validateEntryName(header.filename);
      final mode = (header.externalFileAttributes ?? 0) >> 16;
      final isUnixSymlink =
          header.versionMadeBy >> 8 == 3 && (mode & 0xF000) == 0xA000;
      if (isUnixSymlink) {
        throw const BackupArchiveValidationException('备份包含不支持的符号链接');
      }
    }
  }

  static void _validateEntryName(String name) {
    final normalized = name.replaceAll('\\', '/');
    final segments = normalized.split('/');
    if (normalized.isEmpty ||
        normalized.startsWith('/') ||
        normalized.contains('\u0000') ||
        segments.contains('..') ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
      throw const BackupArchiveValidationException('备份包含不安全的文件路径');
    }
  }
}
