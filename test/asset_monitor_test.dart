import 'dart:async';

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

class _StreamingClient extends http.BaseClient {
  _StreamingClient(this.body);
  final Stream<List<int>> body;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(body, 200);
}
