import 'package:flutter/material.dart';

import '../theme.dart';

/// 目录抽屉，返回点选的章节下标
Future<int?> showChapterSheet(
  BuildContext context, {
  required List<String> titles,
  required int current,
}) {
  bool reversed = false;
  return showModalBottomSheet<int>(
    context: context,
    backgroundColor: kSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setSheet) {
          final count = titles.length;
          return DraggableScrollableSheet(
            expand: false,
            initialChildSize: 0.62,
            minChildSize: 0.35,
            maxChildSize: 0.92,
            builder: (ctx, scrollController) {
              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 14, 8, 6),
                    child: Row(
                      children: [
                        const Text(
                          '目录',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          '共 $count 章 · 当前第 ${current + 1} 章',
                          style: TextStyle(
                            fontSize: 12,
                            color: kSubText,
                          ),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () =>
                              setSheet(() => reversed = !reversed),
                          child: Text(
                            reversed ? '正序' : '倒序',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: kAccent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: ListView.builder(
                      controller: scrollController,
                      itemCount: count,
                      itemBuilder: (context, i) {
                        final realIndex = reversed ? count - 1 - i : i;
                        final isCurrent = realIndex == current;
                        return ListTile(
                          dense: true,
                          title: Text(
                            titles[realIndex],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              color: isCurrent ? kAccent : null,
                            ),
                          ),
                          trailing: isCurrent
                              ? Icon(
                                  Icons.menu_book,
                                  size: 15,
                                  color: kAccent,
                                )
                              : null,
                          onTap: () => Navigator.pop(ctx, realIndex),
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          );
        },
      );
    },
  );
}
