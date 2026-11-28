import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:rindo/closures/feed_result.dart';
import 'package:rindo/closures/road_closure.dart';
import 'package:rindo/net/feed_exception.dart';
import 'package:rindo/net/feed_fetch.dart';

FeedException _error(String message) => FeedException('test feed', message);
final _url = Uri.parse('https://feed.example/data.json');

/// A transport which honours abortion both before headers and during a body.
class _StalledClient extends http.BaseClient {
  _StalledClient({required this.headers});
  final bool headers;
  bool aborted = false;
  bool cancelled = false;
  int attempts = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    attempts++;
    expect(request, isA<http.AbortableRequest>());
    final pending = Completer<http.StreamedResponse>();
    final body = StreamController<List<int>>(onCancel: () => cancelled = true);
    (request as http.Abortable).abortTrigger!.then((_) {
      aborted = true;
      if (headers) {
        pending.completeError(http.RequestAbortedException(request.url));
      } else {
        body.addError(http.RequestAbortedException(request.url));
        unawaited(body.close());
      }
    });
    if (!headers) {
      pending.complete(http.StreamedResponse(body.stream, 200));
      body.add(utf8.encode('['));
    }
    return pending.future;
  }
}

Future<List<dynamic>> _fetch(http.Client client) =>
    fetchFeedJson<List<dynamic>>(
      client,
      _url,
      deadline: const Duration(seconds: 10),
      resource: 'data',
      error: _error,
    );

int _isolateIdentity(Uint8List _) => Isolate.current.hashCode;

void main() {
  for (final headers in [true, false]) {
    test(
      'deadline aborts a stalled ${headers ? 'header' : 'body'} transfer',
      () {
        fakeAsync((clock) {
          final client = _StalledClient(headers: headers);
          var timedOut = false;
          _fetch(client).then<void>(
            (_) => fail('a stalled transfer must not succeed'),
            onError: (Object error) {
              expect(error, isA<TimeoutException>());
              timedOut = true;
            },
          );
          clock.flushMicrotasks();
          clock.elapse(const Duration(seconds: 9));
          expect(client.aborted, isFalse);
          clock.elapse(const Duration(seconds: 1));
          expect(timedOut, isTrue);
          expect(client.aborted, isTrue);
          if (!headers) expect(client.cancelled, isTrue);
          expect(client.attempts, 1);
          expect(clock.nonPeriodicTimerCount, 0);
        });
      },
    );
  }

  test('UTF-8 and nested shape checks retain the feed label', () async {
    final client = MockClient(
      (_) async => http.Response.bytes(utf8.encode('{"value":"通行止"}'), 200),
    );
    expect(
      await fetchFeedJson<String>(
        client,
        _url,
        deadline: const Duration(seconds: 10),
        resource: 'data',
        error: _error,
        select: (doc) => doc is Map ? doc['value'] : null,
      ),
      '通行止',
    );
    await expectLater(
      _fetch(client),
      throwsA(
        isA<FeedException>()
            .having((e) => e.source, 'source', 'test feed')
            .having((e) => e.message, 'message', 'data: unexpected shape'),
      ),
    );
  });

  test('status checking precedes decoding and 404 is opt-in empty', () async {
    final client = MockClient((_) async => http.Response('not JSON', 404));
    await expectLater(
      _fetch(client),
      throwsA(
        isA<FeedException>().having((e) => e.message, 'message', 'data 404'),
      ),
    );
    final result = await fetchFeed<List<int>>(
      client,
      _url,
      deadline: const Duration(seconds: 10),
      resource: 'data',
      error: _error,
      onNotFound: () => [],
      parse: (_) => throw StateError('must not parse'),
    );
    expect(result, isEmpty);
  });

  test('success clears the deadline and malformed JSON still fails', () {
    fakeAsync((clock) {
      var settled = false;
      _fetch(
        MockClient((_) async => http.Response('[]', 200)),
      ).then((_) => settled = true);
      clock.flushMicrotasks();
      expect(settled, isTrue);
      expect(clock.nonPeriodicTimerCount, 0);
      _fetch(MockClient((_) async => http.Response('{', 200))).then<void>(
        (_) => fail('invalid JSON must fail'),
        onError: (Object error) => expect(error, isA<FormatException>()),
      );
      clock.flushMicrotasks();
      expect(clock.nonPeriodicTimerCount, 0);
    });
  });

  test('only payloads above 32 KB move to another isolate', () async {
    final current = Isolate.current.hashCode;
    expect(
      await parseFeedBytes(Uint8List(32 * 1024), _isolateIdentity),
      current,
    );
    expect(
      await parseFeedBytes(Uint8List(32 * 1024 + 1), _isolateIdentity),
      isNot(current),
    );
  });

  test('queued work gets its own full transfer deadline', () {
    fakeAsync((clock) {
      final pool = FeedPool(limit: 1);
      final clients = [
        _StalledClient(headers: true),
        _StalledClient(headers: true),
      ];
      var failures = 0;
      for (final client in clients) {
        pool
            .run(() => _fetch(client))
            .then<void>(
              (_) => fail('stalled transfer'),
              onError: (Object error) {
                expect(error, isA<TimeoutException>());
                failures++;
              },
            );
      }
      clock.flushMicrotasks();
      expect(clients[1].attempts, 0);
      clock.elapse(const Duration(seconds: 10));
      expect(failures, 1);
      expect(clients[1].attempts, 1);
      expect(clients[1].aborted, isFalse);
      clock.elapse(const Duration(seconds: 9));
      expect(failures, 1);
      clock.elapse(const Duration(seconds: 1));
      expect(failures, 2);
    });
  });

  test(
    'LastGood stores empty successes and expires without renewing failures',
    () async {
      var now = DateTime.utc(2026);
      final cache = LastGood<String>(now: () => now);
      final closures = [
        RoadClosure(
          id: 'one',
          point: const LatLng(35, 139),
          roadName: '国道1号',
          restriction: '通行止',
          sourceName: 'test',
          sourceUrl: _url,
        ),
      ];
      final first = await cache.fetchOr('a', () async => closures);
      expect(first, (closures, true, null));
      final error = StateError('offline');
      final fallback = await cache.fetchOr('a', () async => throw error);
      expect(fallback, (closures, false, error));
      expect(await cache.fetchOr('a', null), (closures, false, null));
      expect(await cache.fetchOr('unknown', null), (null, false, null));
      now = now.add(const Duration(hours: 3, seconds: 1));
      expect(await cache.fetchOr('a', () async => throw error), (
        null,
        false,
        error,
      ));
      expect((await cache.fetchOr('a', () async => [])).$2, isTrue);
      final empty = await cache.fetchOr('a', null);
      expect(empty.$1, isEmpty);
      expect(empty.$2, isFalse);
    },
  );
}
