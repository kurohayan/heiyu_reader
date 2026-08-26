import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../models/models.dart';

class AppDatabase {
  AppDatabase._();
  static final AppDatabase instance = AppDatabase._();
  Database? _db;

  Future<Database> get database async => _db ??= await open();

  Future<Database> open() async {
    final dir = await getDatabasesPath();
    final path = p.join(dir, 'heiyu_reader.db');
    _db = await openDatabase(
      path,
      version: 5,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE books(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            title TEXT NOT NULL,
            author TEXT DEFAULT '',
            cover_path TEXT,
            cover_url TEXT,
            intro TEXT,
            type TEXT NOT NULL,
            path TEXT,
            origin TEXT,
            source_id INTEGER,
            source_name TEXT,
            last_chapter INTEGER DEFAULT 0,
            last_offset REAL DEFAULT 0,
            last_read_at INTEGER DEFAULT 0,
            shelf_id INTEGER DEFAULT 0,
            replace_rules TEXT,
            created_at INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE sources(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            url TEXT UNIQUE,
            json TEXT NOT NULL,
            enabled INTEGER DEFAULT 1
          )
        ''');
        await db.execute('''
          CREATE TABLE chapter_cache(
            book_id INTEGER NOT NULL,
            idx INTEGER NOT NULL,
            title TEXT,
            content TEXT,
            PRIMARY KEY(book_id, idx)
          )
        ''');
        await db.execute('''
          CREATE TABLE shelves(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT UNIQUE,
            sort INTEGER DEFAULT 0,
            created_at INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE bookmarks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id INTEGER NOT NULL,
            chapter INTEGER NOT NULL,
            offset REAL NOT NULL,
            label TEXT,
            created_at INTEGER
          )
        ''');
        await db.execute('''
          CREATE TABLE reading_log(
            day TEXT PRIMARY KEY,
            seconds INTEGER DEFAULT 0,
            chapters INTEGER DEFAULT 0
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE books ADD COLUMN shelf_id INTEGER DEFAULT 0',
          );
          await db.execute('''
            CREATE TABLE shelves(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              name TEXT UNIQUE,
              sort INTEGER DEFAULT 0,
              created_at INTEGER
            )
          ''');
        }
        if (oldVersion < 3) {
          await db.execute('''
            CREATE TABLE bookmarks(
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              book_id INTEGER NOT NULL,
              chapter INTEGER NOT NULL,
              offset REAL NOT NULL,
              label TEXT,
              created_at INTEGER
            )
          ''');
        }
        if (oldVersion < 4) {
          await db.execute(
            'ALTER TABLE books ADD COLUMN last_read_at INTEGER DEFAULT 0',
          );
          await db.execute(
            'UPDATE books SET last_read_at = created_at WHERE last_read_at = 0',
          );
        }
        if (oldVersion < 5) {
          await db.execute(
            'ALTER TABLE books ADD COLUMN replace_rules TEXT',
          );
          await db.execute('''
            CREATE TABLE reading_log(
              day TEXT PRIMARY KEY,
              seconds INTEGER DEFAULT 0,
              chapters INTEGER DEFAULT 0
            )
          ''');
        }
      },
    );
    return _db!;
  }

  // ---------------- 书籍 ----------------

  Future<Book> insertBook(Book book) async {
    final db = await database;
    final id = await db.insert('books', book.toMap());
    book.id = id;
    return book;
  }

  /// shelfId: null=全部, 0=未分类, >0=指定自建书架
  Future<List<Book>> allBooks({int? shelfId}) async {
    final db = await database;
    // 按最后阅读时间倒排；未读过的按收藏时间参与排序
    const order =
        'CASE WHEN last_read_at > 0 THEN last_read_at ELSE created_at END DESC';
    final rows = await db.query(
      'books',
      where: shelfId == null ? null : 'shelf_id = ?',
      whereArgs: shelfId == null ? null : [shelfId],
      orderBy: order,
    );
    return rows.map(Book.fromMap).toList();
  }

  Future<void> deleteBook(int id) async {
    final db = await database;
    await db.delete('books', where: 'id = ?', whereArgs: [id]);
    await db.delete('chapter_cache', where: 'book_id = ?', whereArgs: [id]);
    await db.delete('bookmarks', where: 'book_id = ?', whereArgs: [id]);
  }

  Future<void> updateBook(Book book) async {
    final db = await database;
    await db.update(
      'books',
      book.toMap(),
      where: 'id = ?',
      whereArgs: [book.id],
    );
  }

  Future<void> updateProgress(int bookId, int chapter, double offset) async {
    final db = await database;
    await db.update(
      'books',
      {
        'last_chapter': chapter,
        'last_offset': offset,
        'last_read_at': DateTime.now().millisecondsSinceEpoch,
      },
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }

  Future<Book?> findOnlineBook(String origin, int sourceId) async {
    final db = await database;
    final rows = await db.query(
      'books',
      where: 'origin = ? AND source_id = ?',
      whereArgs: [origin, sourceId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return Book.fromMap(rows.first);
  }

  // ---------------- 书源 ----------------

  Future<BookSource> upsertSource(BookSource src) async {
    final db = await database;
    final id = await db.insert(
      'sources',
      src.toMap()..remove('id'),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    src.id = id;
    return src;
  }

  Future<List<BookSource>> allSources() async {
    final db = await database;
    final rows = await db.query('sources', orderBy: 'id ASC');
    return rows.map(BookSource.fromMap).toList();
  }

  Future<List<BookSource>> enabledSources() async {
    final db = await database;
    final rows = await db.query(
      'sources',
      where: 'enabled = 1',
      orderBy: 'id ASC',
    );
    return rows.map(BookSource.fromMap).toList();
  }

  Future<BookSource?> sourceById(int id) async {
    final db = await database;
    final rows = await db.query(
      'sources',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return BookSource.fromMap(rows.first);
  }

  Future<void> setSourceEnabled(int id, bool enabled) async {
    final db = await database;
    await db.update(
      'sources',
      {'enabled': enabled ? 1 : 0},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> deleteSource(int id) async {
    final db = await database;
    await db.delete('sources', where: 'id = ?', whereArgs: [id]);
  }

  // ---------------- 章节缓存（网络书籍） ----------------

  Future<String?> cachedChapter(int bookId, int idx) async {
    final db = await database;
    final rows = await db.query(
      'chapter_cache',
      columns: ['content'],
      where: 'book_id = ? AND idx = ?',
      whereArgs: [bookId, idx],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return rows.first['content'] as String?;
  }

  /// 某本书已缓存的章节数
  Future<int> cachedChapterCount(int bookId) async {
    final db = await database;
    final r = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM chapter_cache WHERE book_id = ?',
      [bookId],
    );
    return (r.first['c'] as int?) ?? 0;
  }

  /// 某本书所有已缓存章节（用于全本搜索）
  Future<List<(int, String)>> cachedChapters(int bookId) async {
    final db = await database;
    final rows = await db.query(
      'chapter_cache',
      columns: ['idx', 'content'],
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'idx ASC',
    );
    return [
      for (final r in rows)
        (
          (r['idx'] as int?) ?? 0,
          (r['content'] as String?) ?? '',
        ),
    ];
  }

  /// 清除某本书的章节缓存（换源时使用）
  Future<void> clearChapterCacheForBook(int bookId) async {
    final db = await database;
    await db.delete('chapter_cache', where: 'book_id = ?', whereArgs: [bookId]);
  }

  Future<void> cacheChapter(
    int bookId,
    int idx,
    String title,
    String content,
  ) async {
    final db = await database;
    await db.insert(
      'chapter_cache',
      {'book_id': bookId, 'idx': idx, 'title': title, 'content': content},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> clearChapterCache() async {
    final db = await database;
    await db.delete('chapter_cache');
  }

  // ---------------- 阅读点 ----------------

  Future<ReadingBookmark> addBookmark(ReadingBookmark bookmark) async {
    final db = await database;
    final id = await db.insert('bookmarks', bookmark.toMap());
    return ReadingBookmark(
      id: id,
      bookId: bookmark.bookId,
      chapter: bookmark.chapter,
      offset: bookmark.offset,
      label: bookmark.label,
      createdAt: bookmark.createdAt,
    );
  }

  Future<List<ReadingBookmark>> bookmarksOf(int bookId) async {
    final db = await database;
    final rows = await db.query(
      'bookmarks',
      where: 'book_id = ?',
      whereArgs: [bookId],
      orderBy: 'created_at DESC',
    );
    return rows.map(ReadingBookmark.fromMap).toList();
  }

  /// 全部阅读点（备份导出用）
  Future<List<ReadingBookmark>> allBookmarks() async {
    final db = await database;
    final rows = await db.query('bookmarks', orderBy: 'created_at DESC');
    return rows.map(ReadingBookmark.fromMap).toList();
  }

  Future<void> deleteBookmark(int id) async {
    final db = await database;
    await db.delete('bookmarks', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteBookmarksOf(int bookId) async {
    final db = await database;
    await db.delete('bookmarks', where: 'book_id = ?', whereArgs: [bookId]);
  }

  // ---------------- 书架分组 ----------------

  Future<List<ShelfGroup>> shelves() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT shelves.id, shelves.name, COUNT(books.id) AS cnt
      FROM shelves
      LEFT JOIN books ON books.shelf_id = shelves.id
      GROUP BY shelves.id
      ORDER BY shelves.id ASC
    ''');
    return rows.map(ShelfGroup.fromMap).toList();
  }

  Future<int> uncategorizedCount() async {
    final db = await database;
    final r = await db.rawQuery(
      'SELECT COUNT(*) AS c FROM books WHERE shelf_id = 0',
    );
    return (r.first['c'] as int?) ?? 0;
  }

  /// 新建书架，重名抛错
  Future<ShelfGroup> createShelf(String name) async {
    final db = await database;
    try {
      final id = await db.insert('shelves', {
        'name': name.trim(),
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
      return ShelfGroup(id: id, name: name.trim());
    } catch (_) {
      throw '已存在同名书架';
    }
  }

  Future<void> renameShelf(int id, String name) async {
    final db = await database;
    try {
      await db.update(
        'shelves',
        {'name': name.trim()},
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (_) {
      throw '已存在同名书架';
    }
  }

  /// 删除书架：命中书籍回归未分类
  Future<void> deleteShelf(int id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update(
        'books',
        {'shelf_id': 0},
        where: 'shelf_id = ?',
        whereArgs: [id],
      );
      await txn.delete('shelves', where: 'id = ?', whereArgs: [id]);
    });
  }

  Future<void> moveBook(int bookId, int shelfId) async {
    final db = await database;
    await db.update(
      'books',
      {'shelf_id': shelfId},
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }

  // ---------------- 净化规则 ----------------

  Future<void> updateReplaceRules(int bookId, String? rulesJson) async {
    final db = await database;
    await db.update(
      'books',
      {'replace_rules': rulesJson},
      where: 'id = ?',
      whereArgs: [bookId],
    );
  }

  // ---------------- 阅读统计 ----------------

  static String _today() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)}';
  }

  Future<void> addReadingStat(int seconds, {int chapters = 0}) async {
    final db = await database;
    await db.rawInsert('''
      INSERT INTO reading_log(day, seconds, chapters)
      VALUES(?, ?, ?)
      ON CONFLICT(day) DO UPDATE SET
        seconds = seconds + excluded.seconds,
        chapters = chapters + excluded.chapters
    ''', [_today(), seconds, chapters]);
  }

  /// 今日秒数 / 总秒数 / 总章数 / 连续阅读天数
  Future<({int today, int total, int chapters, int streak})>
      readingStats() async {
    final db = await database;
    final rows = await db.query('reading_log', orderBy: 'day DESC');
    final today = _today();
    var todaySec = 0;
    var total = 0;
    var chapters = 0;
    for (final r in rows) {
      final s = (r['seconds'] as int?) ?? 0;
      total += s;
      chapters += (r['chapters'] as int?) ?? 0;
      if (r['day'] == today) todaySec = s;
    }
    // 连续天数：从今天或昨天往前数
    var streak = 0;
    var cursor = DateTime.now();
    final days = {for (final r in rows) '${r['day']}'};
    if (!days.contains(today)) {
      cursor = cursor.subtract(const Duration(days: 1));
    }
    while (true) {
      String two(int v) => v.toString().padLeft(2, '0');
      final key = '${cursor.year}-${two(cursor.month)}-${two(cursor.day)}';
      if (!days.contains(key)) break;
      streak++;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return (today: todaySec, total: total, chapters: chapters, streak: streak);
  }
}
