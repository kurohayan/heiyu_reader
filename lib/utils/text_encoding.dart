import 'dart:convert';
import 'dart:typed_data';

import 'gbk_table.dart';

/// GBK / gb18030 双字节解码（基于 WHATWG Encoding 标准码表）
String decodeGbk(Uint8List bytes) {
  final buf = StringBuffer();
  int i = 0;
  final n = bytes.length;
  while (i < n) {
    final b = bytes[i];
    if (b < 0x80) {
      buf.writeCharCode(b);
      i++;
      continue;
    }
    if (b >= 0x81 && b <= 0xFE && i + 1 < n) {
      final t = bytes[i + 1];
      if ((t >= 0x40 && t <= 0x7E) || (t >= 0x80 && t <= 0xFE)) {
        final offset = t < 0x7F ? 0x40 : 0x41;
        final pointer = (b - 0x81) * 190 + (t - offset);
        final cp =
            (pointer >= 0 && pointer < kGbkTable.length)
                ? kGbkTable[pointer]
                : 0;
        buf.writeCharCode(cp != 0 ? cp : 0xFFFD);
        i += 2;
        continue;
      }
    }
    buf.writeCharCode(0xFFFD);
    i++;
  }
  return buf.toString();
}

String _utf16le(Uint8List bytes) {
  final units = <int>[];
  for (int i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i] | (bytes[i + 1] << 8));
  }
  return String.fromCharCodes(units);
}

String _utf16be(Uint8List bytes) {
  final units = <int>[];
  for (int i = 0; i + 1 < bytes.length; i += 2) {
    units.add(bytes[i + 1] | (bytes[i] << 8));
  }
  return String.fromCharCodes(units);
}

class DecodeResult {
  final String text;
  final String encoding;
  const DecodeResult(this.text, this.encoding);
}

/// 自动检测文本编码：BOM → UTF-8 严格校验 → GBK 兜底
DecodeResult decodeTextBytes(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return DecodeResult(
      utf8.decode(bytes.sublist(3), allowMalformed: true),
      'utf-8',
    );
  }
  if (bytes.length >= 2) {
    if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
      return DecodeResult(_utf16le(bytes.sublist(2)), 'utf-16le');
    }
    if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
      return DecodeResult(_utf16be(bytes.sublist(2)), 'utf-16be');
    }
  }
  try {
    return DecodeResult(
      const Utf8Decoder(allowMalformed: false).convert(bytes),
      'utf-8',
    );
  } catch (_) {
    return DecodeResult(decodeGbk(bytes), 'gbk');
  }
}

/// 从 HTTP Content-Type 头中提取 charset
String? charsetFromContentType(String? contentType) {
  if (contentType == null) return null;
  final m = RegExp(r'charset\s*=\s*([\w\-]+)', caseSensitive: false)
      .firstMatch(contentType);
  return m?.group(1)?.toLowerCase();
}

/// 嗅探 HTML 头部 <meta charset>（按 latin1 粗扫描前 2048 字节）
String? sniffHtmlCharset(Uint8List bytes) {
  final n = bytes.length < 2048 ? bytes.length : 2048;
  final head = latin1.decode(bytes.sublist(0, n));
  final m = RegExp(
    r'''charset\s*=\s*["']?\s*([\w\-]+)''',
    caseSensitive: false,
  ).firstMatch(head);
  return m?.group(1)?.toLowerCase();
}

const Set<String> _gbkFamily = {'gbk', 'gb2312', 'gb18030', 'cp936'};

Map<int, int>? _gbkReverse;

/// Unicode → GBK 字节（用于 `ie=gbk` 类型的书源搜索）
List<int> encodeGbk(String s) {
  final reverse = _gbkReverse ??= {
    for (int pointer = 0; pointer < kGbkTable.length; pointer++)
      if (kGbkTable[pointer] != 0) kGbkTable[pointer]: pointer,
  };
  final out = <int>[];
  for (final rune in s.runes) {
    if (rune < 0x80) {
      out.add(rune);
      continue;
    }
    final pointer = reverse[rune];
    if (pointer == null) {
      out.add(0x3F); // 无映射字符用 ? 代替
      continue;
    }
    final lead = pointer ~/ 190 + 0x81;
    final remainder = pointer % 190;
    out
      ..add(lead)
      ..add(remainder < 0x3F ? remainder + 0x40 : remainder + 0x41);
  }
  return out;
}

/// 将关键词按 GBK 字节做 URL 百分号编码。
String gbkQueryComponent(String s) {
  const hex = '0123456789ABCDEF';
  final buf = StringBuffer();
  for (final byte in encodeGbk(s)) {
    final unreserved =
        (byte >= 0x30 && byte <= 0x39) ||
        (byte >= 0x41 && byte <= 0x5A) ||
        (byte >= 0x61 && byte <= 0x7A) ||
        byte == 0x2D ||
        byte == 0x5F ||
        byte == 0x2E ||
        byte == 0x7E;
    if (unreserved) {
      buf.writeCharCode(byte);
    } else {
      buf
        ..write('%')
        ..write(hex[byte >> 4])
        ..write(hex[byte & 0x0F]);
    }
  }
  return buf.toString();
}

/// 网页字节 → 字符串（header charset → meta 嗅探 → UTF-8 严格 → GBK 兜底）
String decodeHtmlBytes(Uint8List bytes, String? contentType) {
  String? charset = charsetFromContentType(contentType) ??
      sniffHtmlCharset(bytes);
  if (charset != null && _gbkFamily.contains(charset)) {
    return decodeGbk(bytes);
  }
  try {
    return const Utf8Decoder(allowMalformed: false).convert(bytes);
  } catch (_) {
    return decodeGbk(bytes);
  }
}
