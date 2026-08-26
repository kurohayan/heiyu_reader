import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heiyu_reader/services/wifi_server.dart';

void main() {
  test('WiFi token comparison is exact and rejects different lengths', () {
    expect(WifiServer.tokensEqual('session-token', 'session-token'), isTrue);
    expect(WifiServer.tokensEqual('session-token', 'session-tokeN'), isFalse);
    expect(WifiServer.tokensEqual('session-token', 'session-token-extra'),
        isFalse);
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

  test('HTTP page requires the runtime token and exposes it in its links',
      () async {
    final server = WifiServer.forTesting(
      bindAddress: InternetAddress.loopbackIPv4,
      ipProvider: () async => ['127.0.0.1'],
    );
    final client = HttpClient();
    try {
      await server.start(preferredPort: 0);
      final firstToken = server.token;
      expect(firstToken, isNotNull);
      expect(server.url, contains('token='));

      final denied = await client.getUrl(Uri.parse('${server.baseUrl}/'));
      final deniedResponse = await denied.close();
      expect(deniedResponse.statusCode, HttpStatus.unauthorized);
      await deniedResponse.drain<void>();

      final pageRequest = await client.getUrl(Uri.parse(server.url));
      final pageResponse = await pageRequest.close();
      expect(pageResponse.statusCode, HttpStatus.ok);
      final page = await utf8.decoder.bind(pageResponse).join();
      expect(page, contains(jsonEncode(firstToken)));
      expect(page, contains('/backup?token='));

      await server.stop();
      expect(server.token, isNull);
      await server.start(preferredPort: 0);
      expect(server.token, isNot(firstToken));
    } finally {
      await server.stop();
      client.close(force: true);
    }
  });
}
