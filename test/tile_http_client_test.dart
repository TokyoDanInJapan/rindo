import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:rindo/net/rekey_safe_tile_provider.dart';
import 'package:rindo/net/tile_http_client.dart';

/// flutter_map decides what a failed tile fetch means by sniffing the exception
/// message, and resolves any [http.ClientException] saying "closed" or "cancel"
/// as a *successful* transparent tile. dart:io words ordinary mid-request
/// network loss exactly that way, so a dropped connection used to leave a
/// silent, permanent hole: no error callback, no failed-tile banner, no retry.
/// The tile client re-types those failures; these tests pin that, and pin the
/// two cancellations that must stay cancellations.

/// Fails every request with [error]; counts attempts so the retry behaviour
/// around the re-typing is visible.
class _FailingClient extends http.BaseClient {
  _FailingClient(this.error);

  final Object error;
  int attempts = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    attempts++;
    throw error;
  }
}

/// Answers with headers, then drops the connection part-way through the body -
/// the handover/doze case, which arrives on the stream rather than from send().
class _TruncatingClient extends http.BaseClient {
  _TruncatingClient(this.error);

  final Object error;
  int attempts = 0;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    attempts++;
    return http.StreamedResponse(
      Stream<List<int>>.error(error),
      200,
      request: request,
    );
  }
}

const _dropped = 'Connection closed before full header was received';
const _url = 'https://tiles.example/{z}/{x}/{y}.png';

/// Pumps a tile layer over [transport] and returns the errors flutter_map
/// reported through `errorTileCallback` - empty means the failure was swallowed.
Future<List<Object>> tileErrors(WidgetTester t, http.Client transport) async {
  final errors = <Object>[];
  final client = tileHttpClient(transport: transport);
  addTearDown(client.close);
  await t.pumpWidget(
    MaterialApp(
      home: FlutterMap(
        options: const MapOptions(
          initialCenter: LatLng(35, 139),
          initialZoom: 10,
        ),
        children: [
          TileLayer(
            urlTemplate: _url,
            tileProvider: RekeySafeTileProvider(
              httpClient: client,
              cachingProvider: const DisabledMapCachingProvider(),
            ),
            errorTileCallback: (_, e, _) => errors.add(e),
          ),
        ],
      ),
    ),
  );
  // Settling needs both clocks: RetryClient's three backoff delays are timers
  // on the test's fake clock, while the body read hands the failure onwards
  // through real async that only runAsync lets progress. So alternate, and stop
  // as soon as the callback has fired.
  for (var i = 0; i < 8 && errors.isEmpty; i++) {
    await t.pump(const Duration(seconds: 1));
    await t.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
  }
  await t.pump();
  return errors;
}

void main() {
  group('a dropped connection is a failed tile, not an empty one', () {
    testWidgets('when it fails before the headers', (t) async {
      final errors = await tileErrors(
        t,
        _FailingClient(http.ClientException(_dropped, Uri.parse(_url))),
      );
      expect(
        errors,
        isNotEmpty,
        reason:
            'flutter_map read "closed" as a cancellation and resolved the tile '
            'as transparent - a silent hole nothing can recover',
      );
      expect(errors.first, isA<TileFetchException>());
      // The wording downstream classifies on must survive verbatim.
      expect('${errors.first}', contains(_dropped));
    });

    testWidgets('when it fails part-way through the body', (t) async {
      final errors = await tileErrors(
        t,
        _TruncatingClient(
          http.ClientException(
            'Connection closed while receiving data',
            Uri.parse(_url),
          ),
        ),
      );
      expect(errors, isNotEmpty);
      expect(errors.first, isA<TileFetchException>());
    });
  });

  group('genuine cancellations stay cancellations', () {
    test('our own close() during teardown is left alone', () async {
      final inner = _FailingClient(
        http.ClientException(
          'HTTP request failed. Client is already closed.',
          Uri.parse(_url),
        ),
      );
      final client = tileHttpClient(transport: inner);
      await expectLater(
        client.get(Uri.parse('https://tiles.example/10/1/1.png')),
        throwsA(
          isA<http.ClientException>().having(
            (e) => e.message,
            'message',
            contains('already closed'),
          ),
        ),
      );
    });

    test('an aborted request keeps its type, so it still counts as a '
        'cancellation', () async {
      final inner = _FailingClient(
        http.RequestAbortedException(Uri.parse(_url)),
      );
      final client = tileHttpClient(transport: inner);
      await expectLater(
        client.get(Uri.parse('https://tiles.example/10/1/1.png')),
        throwsA(isA<http.RequestAbortedException>()),
      );
      // RetryClient must not have re-sent an aborted request either.
      expect(inner.attempts, 1);
    });
  });

  test('re-typing happens outside the retries, so a drop is still retried', () {
    // fakeAsync via FakeTimers isn't available here, so assert on the attempt
    // count once the future settles rather than on wall-clock timing.
    final inner = _FailingClient(
      http.ClientException(_dropped, Uri.parse(_url)),
    );
    final client = tileHttpClient(transport: inner);
    return expectLater(
      client.get(Uri.parse('https://tiles.example/10/1/1.png')),
      throwsA(isA<TileFetchException>()),
    ).then((_) {
      expect(
        inner.attempts,
        greaterThan(1),
        reason: 'a dropped connection is worth retrying before it surfaces',
      );
    });
  });
}
