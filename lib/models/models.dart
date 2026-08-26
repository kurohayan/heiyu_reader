/// 书架书籍。type: txt / epub / online（网络书源书籍）
class Book {
  int? id;
  String title;
  String author;
  String? coverPath; // 本地封面文件
  String? coverUrl; // 网络封面
  String? intro;
  String type;
  String? path; // 本地文件路径
  String? origin; // 书源站书籍详情页 URL（online）
  int? sourceId; // 所属书源 id（online）
  String? sourceName;
  int lastChapter;
  double lastOffset;
  int createdAt;
  int lastReadAt; // 最后阅读时间戳（0=未读过）
  int shelfId; // 0/未分类；>0 对应 shelves 表
  String? replaceRules; // 净化替换规则 JSON [{pattern,replace,enabled}]

  Book({
    this.id,
    required this.title,
    this.author = '',
    this.coverPath,
    this.coverUrl,
    this.intro,
    required this.type,
    this.path,
    this.origin,
    this.sourceId,
    this.sourceName,
    this.lastChapter = 0,
    this.lastOffset = 0,
    this.lastReadAt = 0,
    this.shelfId = 0,
    this.replaceRules,
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  bool get isLocal => type == 'txt' || type == 'epub';
  bool get isOnline => type == 'online';

  factory Book.fromMap(Map<String, Object?> m) {
    return Book(
      id: m['id'] as int?,
      title: (m['title'] as String?) ?? '未命名',
      author: (m['author'] as String?) ?? '',
      coverPath: m['cover_path'] as String?,
      coverUrl: m['cover_url'] as String?,
      intro: m['intro'] as String?,
      type: (m['type'] as String?) ?? 'txt',
      path: m['path'] as String?,
      origin: m['origin'] as String?,
      sourceId: m['source_id'] as int?,
      sourceName: m['source_name'] as String?,
      lastChapter: (m['last_chapter'] as int?) ?? 0,
      lastOffset: ((m['last_offset'] as num?) ?? 0).toDouble(),
      lastReadAt: (m['last_read_at'] as int?) ?? 0,
      shelfId: (m['shelf_id'] as int?) ?? 0,
      replaceRules: m['replace_rules'] as String?,
      createdAt: m['created_at'] as int?,
    );
  }

  Map<String, Object?> toMap() {
    return {
      if (id != null) 'id': id,
      'title': title,
      'author': author,
      'cover_path': coverPath,
      'cover_url': coverUrl,
      'intro': intro,
      'type': type,
      'path': path,
      'origin': origin,
      'source_id': sourceId,
      'source_name': sourceName,
      'last_chapter': lastChapter,
      'last_offset': lastOffset,
      'last_read_at': lastReadAt,
      'shelf_id': shelfId,
      'replace_rules': replaceRules,
      'created_at': createdAt,
    };
  }
}

/// 书架分组（用户自建的；内置「全部/未分类」不入库）
class ShelfGroup {
  int? id;
  String name;
  int bookCount;

  ShelfGroup({this.id, required this.name, this.bookCount = 0});

  factory ShelfGroup.fromMap(Map<String, Object?> m) {
    return ShelfGroup(
      id: m['id'] as int?,
      name: (m['name'] as String?) ?? '',
      bookCount: (m['cnt'] as int?) ?? 0,
    );
  }
}

/// 第三方书源（兼容「阅读 legado」书源 JSON 的常用子集）
class BookSource {
  int? id;
  String name;
  String url; // bookSourceUrl，作为唯一标识
  String json; // 原始书源规则 JSON
  bool enabled;

  BookSource({
    this.id,
    required this.name,
    required this.url,
    required this.json,
    this.enabled = true,
  });

  factory BookSource.fromMap(Map<String, Object?> m) {
    return BookSource(
      id: m['id'] as int?,
      name: (m['name'] as String?) ?? '未命名书源',
      url: (m['url'] as String?) ?? '',
      json: (m['json'] as String?) ?? '{}',
      enabled: ((m['enabled'] as int?) ?? 1) == 1,
    );
  }

  Map<String, Object?> toMap() {
    return {
      if (id != null) 'id': id,
      'name': name,
      'url': url,
      'json': json,
      'enabled': enabled ? 1 : 0,
    };
  }
}

/// 阅读点（手动收藏的阅读位置，一本书可有多条）
class ReadingBookmark {
  final int? id;
  final int bookId;
  final int chapter;
  final double offset; // 章内位置比例（滚动比例或页码比例）
  final String label; // 记录时的章节名快照
  final int createdAt;

  ReadingBookmark({
    this.id,
    required this.bookId,
    required this.chapter,
    required this.offset,
    this.label = '',
    int? createdAt,
  }) : createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch;

  factory ReadingBookmark.fromMap(Map<String, Object?> m) {
    return ReadingBookmark(
      id: m['id'] as int?,
      bookId: (m['book_id'] as int?) ?? 0,
      chapter: (m['chapter'] as int?) ?? 0,
      offset: ((m['offset'] as num?) ?? 0).toDouble(),
      label: (m['label'] as String?) ?? '',
      createdAt: m['created_at'] as int?,
    );
  }

  Map<String, Object?> toMap() {
    return {
      if (id != null) 'id': id,
      'book_id': bookId,
      'chapter': chapter,
      'offset': offset,
      'label': label,
      'created_at': createdAt,
    };
  }

  String get timeLabel {
    final t = DateTime.fromMillisecondsSinceEpoch(createdAt);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
  }
}

/// 阅读内容片段：一段文字或一张图片（EPUB 内联图片用）
class ReaderSegment {
  final String? text;
  final String? image; // epub zip 内的原始 src 引用
  const ReaderSegment.text(this.text) : image = null;
  const ReaderSegment.image(this.image) : text = null;
  bool get isImage => image != null;
}

/// TXT 分章结果（正文区间的字符偏移）
class TxtChapter {
  final String title;
  final int start;
  final int end;
  const TxtChapter(this.title, this.start, this.end);
}

/// EPUB 章节（spine 条目）
class EpubChapter {
  final String title;
  final String href; // zip 内路径
  const EpubChapter(this.title, this.href);
}

/// 书源目录条目
class TocItem {
  final String name;
  final String url;
  const TocItem(this.name, this.url);
}

/// 搜索结果条目
class SearchResultItem {
  final String name;
  final String author;
  final String? coverUrl;
  final String? intro;
  final String? lastChapter;
  final String bookUrl;
  final int sourceId;
  final String sourceName;

  SearchResultItem({
    required this.name,
    this.author = '',
    this.coverUrl,
    this.intro,
    this.lastChapter,
    required this.bookUrl,
    required this.sourceId,
    required this.sourceName,
  });
}
