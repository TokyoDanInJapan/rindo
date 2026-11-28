import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rindo/jma/jma_api.dart';
import 'package:rindo/net/asset_monitor.dart';
import 'package:rindo/screens/radar_map/debug_sheet.dart';

/// Unit tests for the asset-loading instrumentation behind the debug sheet.

Uri _cyclosm(int z, int x, String y) =>
    Uri.parse('https://a.tile-cyclosm.openstreetmap.fr/cyclosm/$z/$x/$y.png');

void main() {
  group('classifyAsset', () {
    test('recognises each URL family', () {
      expect(classifyAsset(_cyclosm(8, 227, '100')), AssetKind.baseTile);
      expect(
        classifyAsset(
          Uri.parse(
            'https://server.arcgisonline.com/ArcGIS/rest/services/'
            'World_Street_Map/MapServer/tile/8/100/227',
          ),
        ),
        AssetKind.baseTile,
      );
      expect(
        classifyAsset(
          Uri.parse(
            '$jmaBase/20260720040000/none/'
            '20260720041500/surf/hrpns/8/227/100.png',
          ),
        ),
        AssetKind.radarTile,
      );
      expect(
        classifyAsset(Uri.parse('$jmaBase/targetTimes_N1.json')),
        AssetKind.radarIndex,
      );
      expect(
        classifyAsset(
          Uri.parse('https://www.jartic.or.jp/d/traffic_info/r1/x'),
        ),
        AssetKind.closures,
      );
      expect(
        classifyAsset(
          Uri.parse('https://www.road-info-prvs.mlit.go.jp/roadinfo/x'),
        ),
        AssetKind.closures,
      );
      expect(
        classifyAsset(
          Uri.parse(
            'https://www.jma.go.jp/bosai/warning/data/landslide/map.json',
          ),
        ),
        AssetKind.closures,
      );
      expect(
        classifyAsset(Uri.parse('https://example.com/whatever')),
        AssetKind.other,
      );
    });
  });

  group('MonitoredClient', () {
    test(
      'success, 404, and network failure land in the right buckets',
      () async {
        final monitor = AssetMonitor();
        final client = MonitoredClient(
          MockClient((req) async {
            if (req.url.path.contains('missing')) return http.Response('', 404);
            if (req.url.path.contains('boom')) {
              throw http.ClientException('SocketException: unreachable');
            }
            return http.Response('x' * 1000, 200);
          }),
          monitor,
        );

        await client.get(_cyclosm(6, 56, '25'));
        await client.get(_cyclosm(6, 56, 'missing'));
        await expectLater(
          client.get(_cyclosm(8, 227, 'boom')),
          throwsA(isA<http.ClientException>()),
        );

        final st = monitor.stats[AssetKind.baseTile]!;
        expect(st.all.ok, 1);
        expect(st.all.okBytes, 1000);
        expect(st.all.notFound, 1);
        expect(st.all.failed, 1);
        expect(st.lastError, contains('SocketException'));
        // Per-zoom split: the ok and 404 were z6, the failure z8.
        expect(st.byZoom[6]!.ok, 1);
        expect(st.byZoom[6]!.notFound, 1);
        expect(st.byZoom[8]!.failed, 1);
        expect(monitor.inFlight, isEmpty);
        expect(monitor.recent.length, 3);
        expect(monitor.recent.last.shortName, 'base 8/227/boom');
        monitor.dispose();
      },
    );

    test('cancelling a body stream mid-read counts as cancelled', () async {
      final monitor = AssetMonitor();
      final body = StreamController<List<int>>();
      final client = MonitoredClient(_StreamingClient(body.stream), monitor);

      final res = await client.send(http.Request('GET', _cyclosm(6, 56, '25')));
      expect(monitor.inFlight, hasLength(1));

      body.add([1, 2, 3]);
      final sub = res.stream.listen((_) {});
      await Future<void>.delayed(Duration.zero);
      await sub.cancel();
      await Future<void>.delayed(Duration.zero);

      final tally = monitor.stats[AssetKind.baseTile]!.all;
      expect(tally.cancelled, 1);
      expect(tally.ok, 0);
      expect(monitor.inFlight, isEmpty);
      expect(monitor.recent.single.bytes, 3);
      await body.close();
      monitor.dispose();
    });

    test("flutter_map's tile aborts count as cancelled, not failed", () async {
      final monitor = AssetMonitor();
      final client = MonitoredClient(
        MockClient((_) async => throw http.RequestAbortedException()),
        monitor,
      );
      await expectLater(
        client.get(_cyclosm(6, 56, '25')),
        throwsA(isA<http.RequestAbortedException>()),
      );
      // An aborted radar tile must not flip its frame to failed either.
      await expectLater(
        client.get(
          Uri.parse(
            '$jmaBase/20260720040000/none/'
            '20260720041500/surf/hrpns/8/227/100.png',
          ),
        ),
        throwsA(isA<http.RequestAbortedException>()),
      );

      final t = monitor.stats[AssetKind.baseTile]!.all;
      expect(t.cancelled, 1);
      expect(t.failed, 0);
      expect(monitor.frameState('20260720041500', 8), FrameLoadState.pending);
      monitor.dispose();
    });

    test(
      'an aborted feed is its own deadline, so it counts as failed',
      () async {
        final monitor = AssetMonitor();
        final client = MonitoredClient(
          MockClient((_) async => throw http.RequestAbortedException()),
          monitor,
        );
        await expectLater(
          client.get(Uri.parse('https://www.jartic.or.jp/d/traffic_info/r1/x')),
          throwsA(isA<http.RequestAbortedException>()),
        );
        final s = monitor.stats[AssetKind.closures]!;
        expect(s.all.failed, 1);
        expect(s.all.cancelled, 0);
        expect(s.lastError, contains('deadline'));
        monitor.dispose();
      },
    );

    test('resetCounters zeroes tallies and the log', () async {
      final monitor = AssetMonitor();
      final client = MonitoredClient(
        MockClient((_) async => http.Response('ok', 200)),
        monitor,
      );
      await client.get(_cyclosm(6, 56, '25'));
      monitor.resetCounters();
      expect(monitor.stats[AssetKind.baseTile]!.all.total, 0);
      expect(monitor.stats[AssetKind.baseTile]!.byZoom, isEmpty);
      expect(monitor.recent, isEmpty);
      monitor.dispose();
    });
  });

  group('frameState', () {
    const valid = '20260720041500';
    Uri radar(int z, [String y = '100']) => Uri.parse(
      '$jmaBase/20260720040000/none/$valid/surf/hrpns/$z/227/$y.png',
    );

    test('pending → loading → loaded lifecycle, keyed by zoom', () async {
      final monitor = AssetMonitor();
      expect(monitor.frameState(valid, 8), FrameLoadState.pending);

      final body = StreamController<List<int>>();
      final client = MonitoredClient(_StreamingClient(body.stream), monitor);
      final res = await client.send(http.Request('GET', radar(8)));
      expect(monitor.frameState(valid, 8), FrameLoadState.loading);

      final drained = res.stream.drain<void>();
      await body.close();
      await drained;
      expect(monitor.frameState(valid, 8), FrameLoadState.loaded);
      // The same frame at another zoom hasn't been touched.
      expect(monitor.frameState(valid, 6), FrameLoadState.pending);
      monitor.dispose();
    });

    test(
      'failures mark the frame failed; 404s count as loaded; reset',
      () async {
        final monitor = AssetMonitor();
        final client = MonitoredClient(
          MockClient(
            (req) async => req.url.path.contains('/8/')
                ? throw http.ClientException('boom')
                : http.Response('', 404),
          ),
          monitor,
        );
        await expectLater(
          client.get(radar(8)),
          throwsA(isA<http.ClientException>()),
        );
        expect(monitor.frameState(valid, 8), FrameLoadState.failed);

        await client.get(radar(6));
        expect(monitor.frameState(valid, 6), FrameLoadState.loaded);

        monitor.resetRadarFrames();
        expect(monitor.frameState(valid, 8), FrameLoadState.pending);
        expect(monitor.frameState(valid, 6), FrameLoadState.pending);
        monitor.dispose();
      },
    );
  });

  group('frameStates', () {
    const valid = '20260720041500';
    Uri radar(int z, [String y = '100']) => Uri.parse(
      '$jmaBase/20260720040000/none/$valid/surf/hrpns/$z/227/$y.png',
    );
    const tick = Duration(milliseconds: 250);

    test('base-tile traffic notifies the monitor but never frameStates', () {
      fakeAsync((async) {
        final monitor = AssetMonitor();
        var all = 0, frames = 0;
        monitor.addListener(() => all++);
        monitor.frameStates.addListener(() => frames++);

        for (var i = 0; i < 20; i++) {
          final r = monitor.begin(_cyclosm(8, 227, '$i'));
          monitor.headersReceived(r, 200);
          monitor.done(r);
          async.elapse(tick);
        }
        expect(all, greaterThan(0));
        expect(frames, 0);
        monitor.dispose();
      });
    });

    test('notifies once per coalesced state change, not once per tile', () {
      fakeAsync((async) {
        final monitor = AssetMonitor();
        var frames = 0;
        monitor.frameStates.addListener(() => frames++);

        // A burst of tiles starts: pending -> loading, one notify.
        final tiles = [
          for (var i = 0; i < 30; i++) monitor.begin(radar(8, '$i')),
        ];
        expect(frames, 0, reason: 'coalesced, not synchronous');
        async.elapse(tick);
        expect(frames, 1);
        expect(monitor.frameState(valid, 8), FrameLoadState.loading);

        // All but one finish: the frame is still loading, so no notify.
        for (final r in tiles.skip(1)) {
          monitor.headersReceived(r, 200);
          monitor.done(r);
        }
        async.elapse(tick);
        expect(frames, 1);

        // The last one lands: loading -> loaded.
        monitor.done(tiles.first..statusCode = 200);
        async.elapse(tick);
        expect(frames, 2);
        expect(monitor.frameState(valid, 8), FrameLoadState.loaded);

        // A frame that goes loaded, loading, loaded inside one window still
        // notifies. The strip also rebuilds on playback, so it may have shown
        // the loading state in between, and must not be left showing it.
        final extra = monitor.begin(radar(8, 'extra'));
        monitor.headersReceived(extra, 200);
        monitor.done(extra);
        async.elapse(tick);
        expect(frames, 3);

        // A failure flips it: loaded -> failed.
        monitor.fail(monitor.begin(radar(8, 'bad')), 'boom');
        async.elapse(tick);
        expect(frames, 4);
        expect(monitor.frameState(valid, 8), FrameLoadState.failed);

        // The reset sends it back to pending, and a reset with nothing to
        // forget is silent.
        monitor.resetRadarFrames();
        async.elapse(tick);
        expect(frames, 5);
        monitor.resetRadarFrames();
        async.elapse(tick);
        expect(frames, 5);
        monitor.dispose();
      });
    });

    test('a cancelled tile returns the frame to pending and says so', () {
      fakeAsync((async) {
        final monitor = AssetMonitor();
        var frames = 0;
        monitor.frameStates.addListener(() => frames++);
        final r = monitor.begin(radar(8));
        async.elapse(tick);
        expect(frames, 1);
        monitor.cancel(r);
        async.elapse(tick);
        expect(frames, 2);
        expect(monitor.frameState(valid, 8), FrameLoadState.pending);
        monitor.dispose();
      });
    });

    test('the in-flight count holds loading until the last tile of that '
        'frame and zoom ends', () {
      final monitor = AssetMonitor();
      final a = monitor.begin(radar(8, 'a'));
      final b = monitor.begin(radar(8, 'b'));
      final other = monitor.begin(radar(6, 'c'));
      monitor.done(a..statusCode = 200);
      expect(monitor.frameState(valid, 8), FrameLoadState.loading);
      monitor.done(b..statusCode = 200);
      monitor.done(b); // a second completion must not count twice
      expect(monitor.frameState(valid, 8), FrameLoadState.loaded);
      expect(monitor.frameState(valid, 6), FrameLoadState.loading);
      // The reset forgets outcomes, not what is still on the wire.
      monitor.resetRadarFrames();
      expect(monitor.frameState(valid, 6), FrameLoadState.loading);
      monitor.cancel(other);
      expect(monitor.frameState(valid, 6), FrameLoadState.pending);
      monitor.dispose();
    });
  });

  group('after dispose', () {
    const valid = '20260720041500';
    final radar = Uri.parse(
      '$jmaBase/20260720040000/none/$valid/surf/hrpns/8/227/100.png',
    );

    test('every entry point is a no-op: no timer, no notify, no throw', () {
      fakeAsync((async) {
        final monitor = AssetMonitor();
        final open = monitor.begin(radar);
        final openBase = monitor.begin(_cyclosm(6, 56, '25'));
        async.elapse(const Duration(seconds: 1));

        var notified = 0;
        monitor.addListener(() => notified++);
        monitor.frameStates.addListener(() => notified++);
        // A notify timer is armed at the moment of disposal.
        monitor.headersReceived(open, 200);
        monitor.dispose();
        expect(async.pendingTimers, isEmpty);

        // The clients close, and their requests complete late.
        monitor.headersReceived(openBase, 200);
        monitor.done(open);
        monitor.fail(openBase, 'Connection closed');
        monitor.cancel(open);
        final late = monitor.begin(radar);
        monitor.headersReceived(late, 200);
        monitor.done(late);
        monitor.resetRadarFrames();
        monitor.resetCounters();
        monitor.dispose();

        expect(async.pendingTimers, isEmpty);
        async.elapse(const Duration(seconds: 5));
        expect(notified, 0);
        expect(monitor.inFlight, isEmpty);
        expect(monitor.stats[AssetKind.radarTile]!.all.total, 0);
      });
    });

    test('a MonitoredClient request that completes after dispose still '
        'delivers its body', () async {
      final monitor = AssetMonitor();
      final body = StreamController<List<int>>();
      final client = MonitoredClient(_StreamingClient(body.stream), monitor);
      final res = await client.send(http.Request('GET', radar));
      monitor.dispose();

      final bytes = res.stream.toBytes();
      body.add([1, 2, 3]);
      await body.close();
      expect(await bytes, [1, 2, 3]);
      // And a request started after dispose passes straight through.
      final after = await client.send(http.Request('GET', radar));
      expect(after.statusCode, 200);
    });
  });

  group('MonitoredClient forwarding', () {
    test('hands the inner client the identical request object', () async {
      // An AbortableRequest carries its abort trigger on the object, so a
      // copy would silently lose cancellation.
      final monitor = AssetMonitor();
      final inner = _RecordingClient();
      final client = MonitoredClient(inner, monitor);

      final plain = http.Request('GET', _cyclosm(6, 56, '25'));
      final abortable = http.AbortableRequest(
        'GET',
        _cyclosm(6, 56, '26'),
        abortTrigger: Completer<void>().future,
      );
      await client.send(plain);
      await client.send(abortable);

      expect(inner.seen, hasLength(2));
      expect(identical(inner.seen[0], plain), isTrue);
      expect(identical(inner.seen[1], abortable), isTrue);
      expect(inner.seen[1], isA<http.Abortable>());
      monitor.dispose();
    });
  });

  group('buildAssetDebugReport', () {
    test('summarises screen state and network tallies', () async {
      final monitor = AssetMonitor();
      final client = MonitoredClient(
        MockClient(
          (req) async => req.url.path.contains('hrpns')
              ? http.Response('r' * 300, 200)
              : http.Response('b' * 2048, 200),
        ),
        monitor,
      );
      await client.get(_cyclosm(6, 56, '25'));
      await client.get(
        Uri.parse(
          '$jmaBase/20260720040000/none/'
          '20260720041500/surf/hrpns/7/113/50.png',
        ),
      );

      final report = buildAssetDebugReport(
        monitor: monitor,
        s: const DebugScreenState(
          cameraZoom: 7.4,
          cameraCenter: '35.681, 139.767',
          offline: true,
          tileEpoch: 2,
          radarNativeZoom: 7,
          frames: [
            JmaFrame(
              basetime: '20260720040000',
              validtime: '20260720041500',
              offsetMin: 15,
            ),
          ],
          closureCount: 12,
          translatorStatus: 'ready',
        ),
      );

      expect(report, contains('camera  z7.40 @ 35.681, 139.767'));
      expect(report, contains('OFFLINE'));
      expect(report, contains('tile epoch    2'));
      expect(report, contains('RADAR FRAMES  1'));
      expect(
        report,
        contains('▶ +15m  13:15 JST · valid 20260720041500 · loaded'),
      );
      expect(report, contains('Base map tiles'));
      // The z-line carries the average body size - the "blank radar tiles at
      // this zoom" tell.
      expect(report, contains('z6  ok 1 (2.0 kB, avg 2.0 kB)'));
      expect(report, contains('Radar tiles'));
      expect(report, contains('z7  ok 1 (300 B, avg 300 B)'));
      expect(report, contains('radar 7/113/50 @0415  200 300 B'));
      monitor.dispose();
    });
  });
}

class _RecordingClient extends http.BaseClient {
  final seen = <http.BaseRequest>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    seen.add(request);
    return http.StreamedResponse(const Stream.empty(), 200);
  }
}

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.body);
  final Stream<List<int>> body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(body, 200);
}
