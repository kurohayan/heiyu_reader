import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heiyu_reader/services/wifi_server.dart';

void main() {
  test('WiFi transfer uses port 12345 by default', () {
    expect(WifiServer.defaultPort, 12345);
  });

  test('limited body reader accepts the boundary and rejects the next byte',
      () async {
    final exact = await WifiServer.readLimitedBytes(
      Stream<List<int>>.fromIterable([
        [1, 2],
        [3, 4],
      ]),
      maxBytes: 4,
    );
    expect(exact, [1, 2, 3, 4]);

    expect(
      WifiServer.readLimitedBytes(
        Stream<List<int>>.fromIterable([
          [1, 2],
          [3],
        ]),
        maxBytes: 2,
      ),
      throwsA(isA<WifiRequestTooLargeException>()),
    );
  });

  test('declared oversized body is rejected before subscribing to the stream',
      () async {
    var subscribed = false;
    final chunks = Stream<List<int>>.multi((controller) {
      subscribed = true;
      controller.add([1]);
      controller.close();
    });

    expect(
      WifiServer.readLimitedBytes(
        chunks,
        maxBytes: 2,
        contentLength: 3,
      ),
      throwsA(isA<WifiRequestTooLargeException>()),
    );
    await Future<void>.delayed(Duration.zero);
    expect(subscribed, isFalse);
  });

  test('HTTP page opens directly without a token', () async {
    final server = WifiServer.forTesting(
      bindAddress: InternetAddress.loopbackIPv4,
      ipProvider: () async => ['127.0.0.1'],
    );
    final client = HttpClient();
    try {
      await server.start(preferredPort: 0);
      expect(server.url, isNot(contains('token=')));

      final pageRequest = await client.getUrl(Uri.parse(server.url));
      final pageResponse = await pageRequest.close();
      expect(pageResponse.statusCode, HttpStatus.ok);
      final page = await utf8.decoder.bind(pageResponse).join();
      expect(page, contains('href="/backup"'));
      expect(page, contains('单个书籍最大 128 MB，备份恢复不限大小'));
    } finally {
      await server.stop();
      client.close(force: true);
    }
  });
}
