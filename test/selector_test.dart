import 'package:flutter_test/flutter_test.dart';
import 'package:heiyu_reader/engine/selector.dart';
import 'package:html/parser.dart' as html_parser;

const _sample = '''
<html><body>
<div class="bookbox">
  <a href="/book/1">斗破苍穹</a>
  <span class="author">天蚕土豆</span>
  <img src="/cover1.jpg">
  <p class="intro">这里是简介一</p>
</div>
<div class="bookbox">
  <a href="/book/2">完美世界</a>
  <span class="author">辰东</span>
  <p class="intro">这里是简介二</p>
</div>
<ul id="list"><li class="chapter"><a href="/c1.html">第一章</a></li>
<li class="chapter"><a href="/c2.html">第二章</a></li></ul>
</body></html>
''';

void main() {
  final doc = html_parser.parse(_sample);

  test('class 选择与链式规则', () {
    final items = RuleSelector.elements(doc, 'class.bookbox');
    expect(items.length, 2);
    expect(RuleSelector.string(items[0], 'tag.a@text'), '斗破苍穹');
    expect(RuleSelector.string(items[0], 'class.author@text'), '天蚕土豆');
    expect(RuleSelector.string(items[0], 'tag.a@href'), '/book/1');
    expect(RuleSelector.string(items[0], 'tag.img@src'), '/cover1.jpg');
    expect(RuleSelector.string(items[1], 'class.intro@text'), '这里是简介二');
  });

  test('索引选择', () {
    expect(RuleSelector.strings(doc, 'class.bookbox.1@tag.a@text'),
        ['完美世界']);
    expect(RuleSelector.string(doc, 'id.list@tag.a@0@text'), '第一章');
  });

  test('回退规则 ||', () {
    // 第二个 bookbox 没有 img，应回退到 a@href
    final items = RuleSelector.elements(doc, 'class.bookbox');
    expect(RuleSelector.string(items[1], 'tag.img@src||tag.a@href'),
        '/book/2');
  });

  test('html 终结符与属性列表', () {
    final hrefs = RuleSelector.strings(doc, 'id.list@tag.a@href');
    expect(hrefs, ['/c1.html', '/c2.html']);
    final names = RuleSelector.strings(doc, 'class.chapter@tag.a@text');
    expect(names, ['第一章', '第二章']);
  });

  test('html 片段转纯文本', () {
    final html = RuleSelector.string(doc, 'class.intro@html');
    expect(html, contains('这里是简介一'));
  });

  test('@css: 与裸 CSS 选择器', () {
    expect(RuleSelector.strings(doc, '@css:.bookbox .author@text'),
        ['天蚕土豆', '辰东']);
    expect(RuleSelector.strings(doc, 'ul#list li a@text'),
        ['第一章', '第二章']);
    expect(RuleSelector.string(doc, '@css:div.bookbox > a@href'), '/book/1');
  });

  test('!排除下标语法（legado）', () {
    expect(RuleSelector.strings(doc, 'id.list@tag.a!0@text'), ['第二章']);
    expect(RuleSelector.strings(doc, 'id.list@tag.a!-1@text'), ['第一章']);
    expect(RuleSelector.strings(doc, 'id.list@tag.a!0:1@text'), []);
  });
}
