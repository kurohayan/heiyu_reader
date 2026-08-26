import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../db/app_database.dart';
import '../models/models.dart';
import '../parsers/epub_parser.dart';
import '../parsers/txt_parser.dart';
import '../state/app_state.dart';
import '../utils/text_encoding.dart';

/// 书籍导入：txt / epub → 入库 + 保存文件 + 提取封面
///
/// 注意：数据库里只存**相对路径**（如 books/xxx.txt、covers/1.jpg），
/// 运行时通过 [resolveFile] 解析成当前沙盒下的实际文件——
/// iOS 重装/更新后容器 UUID 变化也不会让书籍失效。
class BookImporter {
  static Directory? _docs;

  static Future<Directory> docsDir() async {
    return _docs ??= await getApplicationDocumentsDirectory();
  }

  /// 把存储的路径（相对或历史绝对路径）解析为当前沙盒中的文件。
  static Future<File> resolveFile(String stored) async {
    final dir = await docsDir();
    if (!stored.startsWith('/')) {
      return File(p.join(dir.path, stored));
    }
    // 历史数据是绝对路径：取 books/ 或 covers/ 之后的部分重新锚定
    for (final marker in ['/books/', '/covers/']) {
      final i = stored.indexOf(marker);
      if (i >= 0) {
        return File(p.join(dir.path, stored.substring(i + 1)));
      }
    }
    return File(stored); // 非本应用目录的文件，按原样返回
  }

  static Future<Directory> _booksDir() async {
    final docs = await docsDir();
    final dir = Directory(p.join(docs.path, 'books'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static Future<Directory> _coversDir() async {
    final docs = await docsDir();
    final dir = Directory(p.join(docs.path, 'covers'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  static String sanitize(String name) {
    var n = name.replaceAll(RegExp(r'[\\/:*?"<>| -]'), '_').trim();
    if (n.isEmpty) n = 'book_${DateTime.now().millisecondsSinceEpoch}';
    if (n.length > 80) n = n.substring(0, 80);
    return n;
  }

  static Future<Book> importLocalFile(File file) async {
    final bytes = await file.readAsBytes();
    return importBytes(p.basename(file.path), Uint8List.fromList(bytes));
  }

  static Future<Book> importBytes(String fileName, Uint8List bytes) async {
    if (fileName.toLowerCase().endsWith('.epub')) {
      return _importEpub(fileName, bytes);
    }
    return _importTxt(fileName, bytes);
  }

  static Future<Book> _importTxt(String fileName, Uint8List bytes) async {
    final text = decodeTextBytes(bytes).text;
    final dot = fileName.lastIndexOf('.');
    final base = dot > 0 ? fileName.substring(0, dot) : fileName;
    final head = text.length > 600 ? text.substring(0, 600) : text;
    final meta = TxtParser.guessMeta(base, head);

    final dir = await _booksDir();
    final target = await _uniqueFile(dir, fileName);
    await target.writeAsBytes(bytes);

    final book = Book(
      title: meta.title.isEmpty ? '未命名' : meta.title,
      author: meta.author,
      type: 'txt',
      path: p.join('books', p.basename(target.path)),
    );
    await AppDatabase.instance.insertBook(book);
    AppState.notifyShelf();
    return book;
  }

  static Future<Book> _importEpub(String fileName, Uint8List bytes) async {
    final data = EpubParser.parse(bytes);
    final dir = await _booksDir();
    final target = await _uniqueFile(dir, fileName);
    await target.writeAsBytes(bytes);

    final book = Book(
      title: data.title.isEmpty ? '未命名' : data.title,
      author: data.author,
      type: 'epub',
      path: p.join('books', p.basename(target.path)),
    );
    await AppDatabase.instance.insertBook(book);

    if (data.coverBytes != null && book.id != null) {
      final covers = await _coversDir();
      final cf = File(p.join(covers.path, '${book.id}.${data.coverExt}'));
      await cf.writeAsBytes(data.coverBytes!);
      book.coverPath = p.join('covers', p.basename(cf.path));
      await AppDatabase.instance.updateBook(book);
    }
    AppState.notifyShelf();
    return book;
  }

  static Future<File> _uniqueFile(Directory dir, String name) async {
    var f = File(p.join(dir.path, sanitize(name)));
    int i = 1;
    while (await f.exists()) {
      final stem = p.basenameWithoutExtension(name);
      final ext = p.extension(name);
      f = File(p.join(dir.path, sanitize('${stem}_$i$ext')));
      i++;
    }
    return f;
  }

  /// 删除书籍时清理文件
  static Future<void> deleteBookFiles(Book book) async {
    for (final path in [book.path, book.coverPath]) {
      if (path == null) continue;
      try {
        final f = await resolveFile(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }
}
