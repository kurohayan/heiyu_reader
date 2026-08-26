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

  test('restore validation does not impose a file size limit', () {
    final largeFile = ArchiveFile(
      'books/large.epub',
      1024 * 1024 * 1024,
      const <int>[],
    );
    expect(
      () => BackupService.validateRestoreArchiveFiles([largeFile]),
      returnsNormally,
    );
  });

  test('restore validation still rejects unsafe paths', () {
    expect(
      () => BackupService.validateRestoreArchiveFiles([
        ArchiveFile('../outside.txt', 0, const <int>[]),
      ]),
      throwsA(isA<BackupArchiveValidationException>()),
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
      throwsA(isA<BackupArchiveValidationException>()),
    );
  });
}
