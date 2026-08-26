import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:heiyu_reader/utils/text_encoding.dart';

void main() {
  test('GBK 解码', () {
    // 「中文测试」的 GBK 字节序列
    final gbk = Uint8List.fromList(
        [0xD6, 0xD0, 0xCE, 0xC4, 0xB2, 0xE2, 0xCA, 0xD4]);
    expect(decodeGbk(gbk), '中文测试');
  });

  test('UTF-8 文本检测', () {
    final bytes = Uint8List.fromList(utf8.encode('hello 中文'));
    final r = decodeTextBytes(bytes);
    expect(r.encoding, 'utf-8');
    expect(r.text, 'hello 中文');
  });

  test('GBK 文本兜底检测', () {
    final bytes = Uint8List.fromList([0xD6, 0xD0, 0xCE, 0xC4]);
    final r = decodeTextBytes(bytes);
    expect(r.encoding, 'gbk');
    expect(r.text, '中文');
  });

  test('UTF-16LE BOM 检测', () {
    final bytes = <int>[0xFF, 0xFE];
    for (final u in 'ab中'.codeUnits) {
      bytes.add(u & 0xFF);
      bytes.add((u >> 8) & 0xFF);
    }
    final r = decodeTextBytes(Uint8List.fromList(bytes));
    expect(r.text, 'ab中');
  });

  test('HTML meta charset 嗅探', () {
    const html =
        '<html><head><meta charset="gbk"></head><body>x</body></html>';
    expect(sniffHtmlCharset(Uint8List.fromList(utf8.encode(html))), 'gbk');
  });

  test('decodeHtmlBytes 按 header charset 解码', () {
    final bytes = Uint8List.fromList([0xD6, 0xD0, 0xCE, 0xC4]);
    expect(decodeHtmlBytes(bytes, 'text/html; charset=gb2312'), '中文');
  });
}
