import 'package:flutter_test/flutter_test.dart';
import 'package:heiyu_reader/utils/html_text.dart';

void main() {
  test('去除 script/style，保留段落', () {
    final t = htmlToText(
      '<div><script>var ad="x";</script><style>.a{}</style>'
      '<p>第一段</p><p>第二段<br>换行内容</p></div>',
    );
    expect(t.contains('ad'), false);
    expect(t.contains('.a{}'), false);
    expect(t, contains('第一段'));
    expect(t, contains('第二段\n换行内容'));
  });

  test('cleanText 合并多余空行', () {
    final t = cleanText('a\n\n\n\nb\n   \nc');
    expect(t, 'a\n\nb\n\nc');
  });
}
