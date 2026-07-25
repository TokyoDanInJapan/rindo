import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:rindo/net/rekey_safe_tile_provider.dart';

/// Re-keying a tile layer mounts the replacement before Flutter disposes the
/// old one, so the new layer used to adopt the old layer's still-in-flight
/// entry from Flutter's global image cache - then the old layer's disposal
/// aborted that request, and flutter_map resolves an aborted request as a
/// *successful* transparent tile. The new layer ended up permanently "loaded"
/// and permanently blank, with no error and no refetch: the map overlays going
/// dead as the rider navigates around.
///
/// These tests pin the provider's contract: an in-flight entry is never
/// adopted, a finished one always is.

/// Client that never answers, so every tile stays in flight. Records the URLs
/// it was asked for, and lets the test abort in-flight requests the way
/// flutter_map's tile disposal does.
class _HangingClient extends http.BaseClient {
  final requested = <String>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requested.add(request.url.toString());
    final c = Completer<http.StreamedResponse>();
    if (request case http.Abortable(:final abortTrigger?)) {
      abortTrigger.whenComplete(() {
        if (!c.isCompleted) {
          c.completeError(http.RequestAbortedException(request.url));
        }
      });
    }
    return c.future;
  }
}

/// A 1x1 transparent PNG, so a tile can actually finish decoding.
final _pngBytes = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
]);

const _url = 'https://tiles.example/{z}/{x}/{y}.png';

Widget _map(String layerKey, http.Client client) => MaterialApp(
  home: FlutterMap(
    options: const MapOptions(
      initialCenter: LatLng(35, 139),
      initialZoom: 10,
    ),
    children: [
      TileLayer(
        key: ValueKey(layerKey),
        urlTemplate: _url,
        tileProvider: RekeySafeTileProvider(
          httpClient: client,
          cachingProvider: const DisabledMapCachingProvider(),
        ),
      ),
    ],
  ),
);

void main() {
  // The image cache is process-wide, so tests must not inherit each other's
  // entries - that is the whole subject here.
  setUp(() {
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  testWidgets('a re-keyed layer refetches tiles that were in flight', (
    t,
  ) async {
    final client = _HangingClient();
    await t.pumpWidget(_map('epoch-0', client));
    final first = client.requested.length;
    expect(first, greaterThan(0), reason: 'first generation should fetch');

    // The tile-epoch bump / native-zoom switch / frame-set swap: same URLs,
    // new layer key, while every request from the first generation is still
    // on the wire.
    await t.pumpWidget(_map('epoch-1', client));
    await t.pumpAndSettle();

    final refetched = client.requested.sublist(first);
    expect(
      refetched,
      isNotEmpty,
      reason:
          'the new layer adopted the old, about-to-be-aborted image-cache '
          'entries instead of fetching - those tiles would stay blank forever',
    );
    // Every tile the second generation shows must have been asked for again.
    expect(refetched.toSet(), containsAll(client.requested.take(first).toSet()));
  });

  testWidgets('a finished tile is still served from the image cache', (
    t,
  ) async {
    var served = 0;
    final client = MockClient((_) async {
      served++;
      return http.Response.bytes(_pngBytes, 200, headers: {
        'content-type': 'image/png',
      });
    });

    await t.pumpWidget(_map('epoch-0', client));
    // Decoding is real async work off the frame scheduler, so pumpAndSettle
    // alone leaves the cache entries pending; runAsync lets them finish.
    await t.runAsync(() => Future<void>.delayed(const Duration(seconds: 1)));
    await t.pumpAndSettle();
    expect(served, greaterThan(0));
    final afterFirst = served;

    // Nothing is in flight now, so the second generation should reuse the
    // decoded tiles rather than re-download them.
    await t.pumpWidget(_map('epoch-1', client));
    await t.pumpAndSettle();
    expect(served, afterFirst, reason: 'finished tiles should stay cached');
  });
}
