import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rindo/net/tile_disk_cache.dart';

final _png = Uint8List.fromList(List.generate(64, (i) => i));
Uri _cyclosm(String sub, [int y = 1612]) => Uri.parse(
  'https://$sub.tile-cyclosm.openstreetmap.fr/cyclosm/12/3637/$y.png',
);
final _esri = Uri.parse(
  'https://server.arcgisonline.com/ArcGIS/rest/services/'
  'World_Street_Map/MapServer/tile/12/1612/3637',
);

http.Response _tile({
  int status = 200,
  String etag = '"v1"',
  String control = 'max-age=86400',
  List<int>? body,
}) => http.Response.bytes(
  body ?? _png,
  status,
  headers: {
    'content-type': 'image/png',
    'etag': etag,
    'cache-control': control,
  },
);

/// Waits for the cache's background disk writes, which are real file I/O.
Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(done(), isTrue, reason: 'timed out waiting for the disk');
}

void main() {
  late Directory root;
  late DateTime now;
  late List<http.BaseRequest> sent;
  late FutureOr<http.Response> Function(http.BaseRequest) answer;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('tile_cache_test');
    now = DateTime(2026, 11, 29, 9);
    sent = [];
    answer = (_) => _tile();
  });
  tearDown(() => root.delete(recursive: true));

  (CachingTileClient, TileDiskCache) build({int maxBytes = 1 << 20}) {
    final cache = TileDiskCache(
      Future.value(root),
      maxBytes: maxBytes,
      now: () => now,
    );
    final inner = MockClient((req) async {
      sent.add(req);
      return answer(req);
    });
    return (CachingTileClient(inner, cache, now: () => now), cache);
  }

  File stored(String key) => File('${root.path}/tiles/$key');
  const key = 'cyclosm-12-3637-1612';

  test('a stored tile is served from disk while fresh, on every '
      'subdomain', () async {
    final (client, _) = build();
    final first = await client.get(_cyclosm('a'));
    expect(first.bodyBytes, _png);
    await _until(() => stored(key).existsSync());

    final again = await client.get(_cyclosm('c'));
    expect(again.bodyBytes, _png);
    expect(sent, hasLength(1), reason: 'no network for a fresh tile');
    expect(client.stats.hits, 1);
  });

  test('an expired tile is revalidated with its ETag, and a 304 renews '
      'it', () async {
    final (client, _) = build();
    await client.get(_cyclosm('a'));
    await _until(() => stored(key).existsSync());

    now = now.add(const Duration(hours: 25));
    answer = (_) => http.Response('', 304);
    final res = await client.get(_cyclosm('b'));
    expect(res.statusCode, 200);
    expect(res.bodyBytes, _png);
    expect(sent.last.headers['If-None-Match'], '"v1"');
    expect(client.stats.revalidated, 1);

    // The 304 carried no caching headers, so the tile is renewed for its own
    // lifetime, 24 hours, and not the 7-day default.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    now = now.add(const Duration(hours: 23));
    await client.get(_cyclosm('a'));
    expect(sent, hasLength(2), reason: 'still fresh after 23 hours');
    now = now.add(const Duration(hours: 2));
    await client.get(_cyclosm('a'));
    expect(sent, hasLength(3), reason: 'expired after 25 hours');
  });

  test('an expired tile is served when the network fails or the server '
      'errs', () async {
    final (client, _) = build();
    await client.get(_cyclosm('a'));
    await _until(() => stored(key).existsSync());
    now = now.add(const Duration(days: 3));

    answer = (_) => throw const SocketException('no route to host');
    expect((await client.get(_cyclosm('a'))).bodyBytes, _png);
    answer = (_) => http.Response('busy', 503);
    expect((await client.get(_cyclosm('a'))).bodyBytes, _png);
    expect(client.stats.offline, 2);
  });

  test('an expired tile is served when the new transfer breaks off', () async {
    final (client, _) = build();
    await client.get(_cyclosm('a'));
    await _until(() => stored(key).existsSync());
    now = now.add(const Duration(days: 3));

    // A body that delivers one chunk and then loses the connection.
    Stream<List<int>> brokenBody() async* {
      yield _png.sublist(0, 10);
      throw const SocketException('connection reset');
    }

    final broken = CachingTileClient(
      _StreamingClient(brokenBody()),
      TileDiskCache(Future.value(root), now: () => now),
      now: () => now,
    );
    expect((await broken.get(_cyclosm('a'))).bodyBytes, _png);
    expect(broken.stats.offline, 1);
  });

  test(
    'a request cancelled while it revalidates gets no stored copy',
    () async {
      final (_, cache) = build();
      final abort = Completer<void>();
      final client = CachingTileClient(
        MockClient((req) async {
          if (req.headers['If-None-Match'] != null) {
            abort.complete(); // the map gives up on the tile meanwhile
            return http.Response('', 304);
          }
          return _tile();
        }),
        cache,
        now: () => now,
      );
      await client.get(_cyclosm('a'));
      await _until(() => stored(key).existsSync());
      now = now.add(const Duration(days: 3));

      final request = http.AbortableRequest(
        'GET',
        _cyclosm('a'),
        abortTrigger: abort.future,
      );
      await expectLater(
        client.send(request),
        throwsA(isA<http.RequestAbortedException>()),
      );
    },
  );

  test('a 304 that says no-store removes the tile', () async {
    final (client, _) = build();
    await client.get(_cyclosm('a'));
    await _until(() => stored(key).existsSync());
    now = now.add(const Duration(days: 3));
    answer = (_) =>
        http.Response('', 304, headers: {'cache-control': 'No-Store'});
    expect((await client.get(_cyclosm('a'))).bodyBytes, _png);
    await _until(() => !stored(key).existsSync());
  });

  test('freshness takes off the Age, and directives ignore case', () async {
    final (client, _) = build();
    answer = (_) => http.Response.bytes(
      _png,
      200,
      headers: {
        'content-type': 'image/png',
        'cache-control': 'Max-Age=86400',
        'age': '86000',
      },
    );
    await client.get(_cyclosm('a'));
    await _until(() => stored(key).existsSync());
    now = now.add(const Duration(minutes: 10)); // past the 400 s left
    answer = (_) => _tile();
    await client.get(_cyclosm('a'));
    expect(sent, hasLength(2));

    answer = (_) => _tile(control: 'No-Store');
    await client.get(_cyclosm('b', 99));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(stored('cyclosm-12-3637-99').existsSync(), isFalse);
  });

  test('a tile served offline counts as recently used', () async {
    final (client, _) = build();
    await client.get(_cyclosm('a'));
    await _until(() => stored(key).existsSync());
    await stored(key).setLastModified(DateTime(2026, 1, 1));
    now = now.add(const Duration(days: 3));
    answer = (_) => throw const SocketException('no route to host');
    await client.get(_cyclosm('a'));
    await _until(
      () =>
          stored(key).lastModifiedSync().year == now.year &&
          stored(key).lastModifiedSync().month == now.month,
    );
  });

  test('trim leaves a file still being written, and clears old '
      'leftovers', () async {
    final (_, cache) = build(maxBytes: 1);
    final tiles = await Directory('${root.path}/tiles').create();
    final fresh = File('${tiles.path}/$key.1-1.tmp')..writeAsBytesSync(_png);
    final old = File('${tiles.path}/$key.2-2.tmp')..writeAsBytesSync(_png);
    await old.setLastModified(
      DateTime.now().subtract(const Duration(hours: 1)),
    );
    await cache.trim(force: true);
    expect(fresh.existsSync(), isTrue);
    expect(old.existsSync(), isFalse);
  });

  test('a cancelled request is not answered from the cache', () async {
    final (client, _) = build();
    await client.get(_cyclosm('a'));
    await _until(() => stored(key).existsSync());
    now = now.add(const Duration(days: 3));

    answer = (_) => throw http.RequestAbortedException();
    await expectLater(
      client.get(_cyclosm('a')),
      throwsA(isA<http.RequestAbortedException>()),
    );
  });

  test('without a stored copy, a network failure still fails', () async {
    final (client, _) = build();
    answer = (_) => throw const SocketException('no route to host');
    await expectLater(
      client.get(_cyclosm('a')),
      throwsA(isA<SocketException>()),
    );
  });

  test('Esri tiles, errors and no-store responses are never '
      'stored', () async {
    final (client, _) = build();
    await client.get(_esri);
    answer = (_) => _tile(status: 404);
    await client.get(_cyclosm('a', 1));
    answer = (_) => _tile(control: 'no-store');
    await client.get(_cyclosm('a', 2));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final tiles = Directory('${root.path}/tiles');
    final files = tiles.existsSync() ? tiles.listSync() : const [];
    expect(files, isEmpty);
    expect(client.stats.stored, 0);
  });

  test('a body the map stops reading, or one cut short, is not '
      'stored', () async {
    final cache = TileDiskCache(Future.value(root), now: () => now);

    // The map cancels part way through.
    final body = StreamController<List<int>>();
    final cancelled = CachingTileClient(
      _StreamingClient(body.stream),
      cache,
      now: () => now,
    );
    final res = await cancelled.send(http.Request('GET', _cyclosm('a')));
    final sub = res.stream.listen((_) {});
    body.add(_png.sublist(0, 10));
    await Future<void>.delayed(Duration.zero);
    await sub.cancel();
    await body.close();

    // The transfer ends early: fewer bytes than its Content-Length.
    final short = CachingTileClient(
      _StreamingClient(Stream.value(_png.sublist(0, 10))),
      cache,
      now: () => now,
    );
    await short.get(_cyclosm('a'));

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(stored(key).existsSync(), isFalse);
    expect(cancelled.stats.stored + short.stats.stored, 0);
  });

  test('a damaged file is a miss, and is deleted', () async {
    final (client, _) = build();
    await Directory('${root.path}/tiles').create();
    await stored(key).writeAsBytes([1, 2, 3]); // no header line
    final res = await client.get(_cyclosm('a'));
    expect(res.bodyBytes, _png);
    expect(sent, hasLength(1));
  });

  test('trim deletes the least recently used tiles first', () async {
    // Room for about three tiles of 64 bytes plus their header lines.
    final (client, cache) = build(maxBytes: 400);
    for (var y = 1; y <= 5; y++) {
      await client.get(_cyclosm('a', y));
      await _until(() => stored('cyclosm-12-3637-$y').existsSync());
      // Distinct modification times, oldest first.
      await stored(
        'cyclosm-12-3637-$y',
      ).setLastModified(DateTime(2026, 11, 29, 9, y));
    }
    await cache.trim(force: true);
    expect(stored('cyclosm-12-3637-1').existsSync(), isFalse);
    expect(stored('cyclosm-12-3637-5').existsSync(), isTrue);
    final total = Directory(
      '${root.path}/tiles',
    ).listSync().whereType<File>().fold<int>(0, (n, f) => n + f.lengthSync());
    expect(total, lessThanOrEqualTo(360));
  });

  test('no cache directory means no cache, not an error', () async {
    final cache = TileDiskCache(Future.error(StateError('no path')));
    final client = CachingTileClient(
      MockClient((_) async => _tile()),
      cache,
      now: () => now,
    );
    expect((await client.get(_cyclosm('a'))).bodyBytes, _png);
    expect((await client.get(_cyclosm('a'))).bodyBytes, _png);
    expect(client.stats.hits, 0);
  });
}

/// Answers every request with [body] as a streamed 200 tile.
class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.body);
  final Stream<List<int>> body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(
        body,
        200,
        contentLength: _png.length,
        headers: {'content-type': 'image/png'},
      );
}
