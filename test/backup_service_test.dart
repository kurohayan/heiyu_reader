import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heiyu_reader/services/backup_service.dart';

void main() {
  test('online book source id uses the id restored in the destination DB', () {
    expect(BackupService.remapSourceId(17, {17: 42}), 42);
    expect(BackupService.remapSourceId(17, {17: 42, 18: 43}), 42);
  });

  test('an unresolved source id is cleared instead of pointing at an old row',
      () {
    expect(BackupService.remapSourceId(17, {18: 42}), isNull);
    expect(BackupService.remapSourceId(null, {17: 42}), isNull);
  });

  test('restore entry limits reject oversized declared files and totals', () {
    final oversized = ArchiveFile(
      'books/large.epub',
      BackupService.maxRestoreFileBytes + 1,
      const <int>[],
    );
    expect(
      () => BackupService.validateRestoreArchiveFiles([oversized]),
      throwsA(isA<BackupArchiveLimitException>()),
    );

    final total = [
      ArchiveFile(
        'books/a.epub',
        BackupService.maxRestoreFileBytes,
        const <int>[],
      ),
      ArchiveFile(
        'books/b.epub',
        BackupService.maxRestoreFileBytes,
        const <int>[],
      ),
      ArchiveFile(
        'books/c.epub',
        BackupService.maxRestoreFileBytes,
        const <int>[],
      ),
      ArchiveFile(
        'books/d.epub',
        BackupService.maxRestoreFileBytes,
        const <int>[],
      ),
      ArchiveFile(
        'books/e.epub',
        1,
        const <int>[],
      ),
    ];
    expect(
      () => BackupService.validateRestoreArchiveFiles(total),
      throwsA(isA<BackupArchiveLimitException>()),
    );
  });

  test('restore rejects a zip entry whose declared size is a zip bomb',
      () async {
    final archive = Archive()
      ..addFile(ArchiveFile(
        'books/declared-large.epub',
        BackupService.maxRestoreFileBytes + 1,
        const <int>[],
      ));
    final encoded = ZipEncoder().encode(archive);

    expect(
      BackupService.restore(Uint8List.fromList(encoded!)),
      throwsA(isA<BackupArchiveLimitException>()),
    );
  });

  test('restore rejects encrypted zip entries before decoding content',
      () async {
    final archive = Archive()
      ..addFile(ArchiveFile(
        BackupService.manifestName,
        2,
        '{}',
      ));
    final encoded = ZipEncoder(password: 'test-password').encode(archive);

    expect(
      BackupService.restore(Uint8List.fromList(encoded!)),
      throwsA(isA<BackupArchiveLimitException>()),
    );
  });
}
