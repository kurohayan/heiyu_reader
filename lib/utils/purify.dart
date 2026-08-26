import 'dart:convert';

/// 净化替换规则应用：JSON [{pattern, replace, enabled}]
String applyReplaceRules(String text, String? rulesJson) {
  if (rulesJson == null || rulesJson.trim().isEmpty) return text;
  final List<dynamic> rules;
  try {
    final decoded = jsonDecode(rulesJson);
    if (decoded is! List) return text;
    rules = decoded;
  } catch (_) {
    return text;
  }
  var out = text;
  for (final r in rules) {
    if (r is! Map) continue;
    if (r['enabled'] == false) continue;
    final pattern = '${r['pattern'] ?? ''}';
    if (pattern.isEmpty) continue;
    final replacement = '${r['replace'] ?? ''}';
    try {
      // multiLine 但不 dotAll：`.*` 只匹配到行尾，符合书源净化习惯
      out = out.replaceAll(
        RegExp(pattern, multiLine: true),
        replacement,
      );
    } catch (_) {}
  }
  return out;
}
