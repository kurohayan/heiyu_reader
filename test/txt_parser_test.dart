import 'package:flutter_test/flutter_test.dart';
import 'package:heiyu_reader/parsers/txt_parser.dart';

void main() {
  test('按「第X章」标题分章', () {
    final buf = StringBuffer();
    buf.write('这是前言。' * 80);
    for (int i = 1; i <= 6; i++) {
      buf.write('\n第$i章 章节标题$i\n');
      buf.write('这是第$i章的正文内容。' * 20);
    }
    final text = buf.toString();
    final chapters = TxtParser.splitChapters(text);

    expect(chapters.length, greaterThanOrEqualTo(6));
    // 序章 + 6 章
    expect(chapters.first.title, '序章');
    expect(chapters[1].title, contains('第1章'));
    // 区间覆盖完整正文
    expect(chapters.last.end, text.length);
    for (int i = 1; i < chapters.length; i++) {
      expect(chapters[i].start, chapters[i - 1].end);
    }
  });

  test('中文数字章节标题', () {
    final buf = StringBuffer();
    for (final t in ['第一章 起点', '第二章 发展', '第三章 高潮', '第四章 结局']) {
      buf.write('\n$t\n');
      buf.write('正文内容。' * 30);
    }
    final chapters = TxtParser.splitChapters(buf.toString());
    expect(chapters.length, 4);
    expect(chapters.first.title, '第一章 起点');
  });

  test('无章节标记时按定长切块', () {
    final text = '没有任何章节标记的长文本内容。' * 2000;
    final chapters = TxtParser.splitChapters(text);
    expect(chapters.length, greaterThan(1));
    expect(chapters.first.start, 0);
    expect(chapters.last.end, text.length);
    for (int i = 1; i < chapters.length; i++) {
      expect(chapters[i].start, chapters[i - 1].end);
    }
  });

  test('guessMeta 提取书名与作者', () {
    final meta = TxtParser.guessMeta(
      '我的小说.txt',
      '书名：测试书名\n作者：某位作者\n\n第一章 开端',
    );
    expect(meta.title, '测试书名');
    expect(meta.author, '某位作者');

    final meta2 = TxtParser.guessMeta('斗破苍穹.txt', '第一章 内容');
    expect(meta2.title, '斗破苍穹');
  });
}
