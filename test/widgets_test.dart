import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rindo/closures/closure_repository.dart';
import 'package:rindo/closures/seasonal_gates.dart';
import 'package:rindo/jma/jma_api.dart';
import 'package:rindo/net/asset_monitor.dart';
import 'package:rindo/screens/radar_map/closures_controller.dart';
import 'package:rindo/screens/radar_map/debug_sheet.dart';
import 'package:rindo/screens/radar_map/disclaimer.dart';
import 'package:rindo/screens/radar_map/frame_controls.dart';
import 'package:rindo/screens/radar_map/map_banners.dart';
import 'package:rindo/screens/radar_map/map_compass.dart';
import 'package:rindo/screens/radar_map/map_fab_stack.dart';
import 'package:rindo/screens/radar_map/model_download_banner.dart';
import 'package:rindo/screens/radar_map/radar_legend.dart';
import 'package:rindo/screens/radar_map/radar_map_view.dart';
import 'package:rindo/net/tile_status.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:rindo/translate/closure_translator.dart';
import 'package:rindo/translate/translation_controller.dart';

/// Widget tests for the dumb presentation widgets: the emulator covers the
/// integrated map, but nothing else guards "the button/banner disappeared".

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Pumps a full [RadarMapView] with mocked network and closures. URLs the
/// view asks to open land in [opened].
Future<MapController> pumpMap(
  WidgetTester t, {
  List<Uri>? opened,
  LatLng? pin,
  LatLng? rider,
  List<(LatLng, bool)>? places,
}) async {
  final controller = MapController();
  final closures = ClosuresController(
    vsync: const TestVSync(),
    repository: ClosureRepository(
      client: MockClient((_) async => http.Response('nf', 404)),
      seasonal: SeasonalGateSource(gates: const []),
    ),
    english: false,
  );
  addTearDown(closures.dispose);
  if (rider != null) closures.setRider(rider);
  if (pin != null) closures.dropPin(pin);
  await t.pumpWidget(
    MaterialApp(
      home: RadarMapView(
        mapController: controller,
        closures: closures,
        httpClient: MockClient((_) async => http.Response('nf', 404)),
        frames: const [
          JmaFrame(
            basetime: '20260721110000',
            validtime: '20260721110000',
            offsetMin: 0,
          ),
          JmaFrame(
            basetime: '20260721110000',
            validtime: '20260721111500',
            offsetMin: 15,
          ),
        ],
        frameIndex: 0,
        tileEpoch: 0,
        greyscale: false,
        initialCenter: const LatLng(35, 137),
        initialZoom: 10,
        onCameraGesture: () {},
        onLongPress: (_) {},
        onShowPlace: (point, {required pinned}) =>
            places?.add((point, pinned)),
        onShowDetail: (_) {},
        onOpenUrl: (url) => opened?.add(url),
        onTileError: (_, _, _, _) {},
        onRetryTiles: () {},
      ),
    ),
  );
  return controller;
}

MapBanners _banners({
  bool offline = false,
  bool english = false,
  TranslatorStatus status = TranslatorStatus.idle,
  String? translatorError,
  bool translating = false,
  String? radarError,
  String? locationError,
  String? closuresError,
}) => MapBanners(
  offline: offline,
  english: english,
  translatorStatus: status,
  translatorError: translatorError,
  downloadStartedAt: status == TranslatorStatus.downloadingModel
      ? DateTime.now()
      : null,
  translating: translating,
  radarError: radarError,
  locationError: locationError,
  closuresError: closuresError,
);

void main() {
  group('MapBanners', () {
    testWidgets('quiet state shows nothing', (t) async {
      await t.pumpWidget(_host(_banners()));
      expect(find.byType(Card), findsNothing);
    });

    testWidgets('offline coalesces into one connectivity line', (t) async {
      // Offline plus per-source failures: only the one connectivity banner
      // shows; the radar/closures cards are the same outage, so suppressed.
      await t.pumpWidget(
        _host(
          _banners(
            offline: true,
            radarError: 'radar broke',
            closuresError: 'JARTIC: down',
          ),
        ),
      );
      expect(find.textContaining('No connection'), findsOneWidget);
      expect(find.textContaining('radar broke'), findsNothing);
      expect(find.textContaining('JARTIC'), findsNothing);
    });

    testWidgets('online source failures show friendly per-source lines', (
      t,
    ) async {
      await t.pumpWidget(
        _host(
          _banners(
            radarError:
                'ClientException with SocketException: No route to host',
            locationError: 'no gps',
            closuresError: 'server said 500',
          ),
        ),
      );
      // Connectivity-shaped errors collapse to a plain line...
      expect(
        find.textContaining('Radar unavailable. No connection'),
        findsOneWidget,
      );
      // ...non-network ones stay generic but readable.
      expect(
        find.textContaining('Closures unavailable right now'),
        findsOneWidget,
      );
      expect(find.textContaining('no gps'), findsOneWidget);
    });

    testWidgets('model download banner only in English mode', (t) async {
      await t.pumpWidget(
        _host(
          _banners(english: true, status: TranslatorStatus.downloadingModel),
        ),
      );
      expect(find.byType(ModelDownloadBanner), findsOneWidget);
      await t.pumpWidget(
        _host(
          _banners(english: false, status: TranslatorStatus.downloadingModel),
        ),
      );
      expect(find.byType(ModelDownloadBanner), findsNothing);
    });

    testWidgets('translation failure shows the actual error', (t) async {
      await t.pumpWidget(
        _host(
          _banners(
            english: true,
            status: TranslatorStatus.failed,
            translatorError: 'MissingPluginException(...)',
          ),
        ),
      );
      expect(
        find.textContaining('Translation model unavailable'),
        findsOneWidget,
      );
      expect(find.textContaining('MissingPluginException'), findsOneWidget);
    });
  });

  group('ModelDownloadBanner', () {
    testWidgets('shows a bar and the elapsed time', (t) async {
      // The widget measures real wall-clock elapsed (the test clock is
      // fake), so feed it a start 3 s in the past.
      final start = DateTime.now().subtract(const Duration(seconds: 3));
      await t.pumpWidget(_host(ModelDownloadBanner(startedAt: start)));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(find.textContaining('… 3s'), findsOneWidget);
      // Exercise the periodic-rebuild timer path.
      await t.pump(const Duration(seconds: 1));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });
  });

  group('MapFabStack', () {
    testWidgets('all seven controls render and their callbacks fire', (
      t,
    ) async {
      final tapped = <String>[];
      await t.pumpWidget(
        _host(
          MapFabStack(
            routeLoaded: false,
            english: true,
            greyscale: true,
            closureCount: 7,
            closuresLoading: false,
            pinned: false,
            following: true,
            onShowDebug: () => tapped.add('debug'),
            onToggleRoute: () => tapped.add('route'),
            onToggleLanguage: () => tapped.add('lang'),
            onToggleGreyscale: () => tapped.add('grey'),
            onShowClosures: () => tapped.add('closures'),
            onRefresh: () => tapped.add('refresh'),
            onRecenter: () => tapped.add('recenter'),
          ),
        ),
      );
      expect(find.byType(FloatingActionButton), findsNWidgets(7));
      expect(find.text('7'), findsOneWidget); // the closures badge
      expect(find.text('EN'), findsOneWidget);

      await t.tap(find.byIcon(Icons.bug_report_outlined));
      await t.tap(find.byIcon(Icons.route_outlined));
      await t.tap(find.text('EN'));
      await t.tap(find.byIcon(Icons.palette_outlined));
      await t.tap(find.byIcon(Icons.report_gmailerrorred));
      await t.tap(find.byIcon(Icons.refresh));
      await t.tap(find.byIcon(Icons.my_location));
      expect(tapped, [
        'debug',
        'route',
        'lang',
        'grey',
        'closures',
        'refresh',
        'recenter',
      ]);
    });

    testWidgets('state variants: loaded route, japanese, loading spinner, '
        'not following', (t) async {
      await t.pumpWidget(
        _host(
          MapFabStack(
            routeLoaded: true,
            english: false,
            greyscale: false,
            closureCount: 0,
            closuresLoading: true,
            pinned: true,
            following: false,
            onShowDebug: () {},
            onToggleRoute: () {},
            onToggleLanguage: () {},
            onToggleGreyscale: () {},
            onShowClosures: () {},
            onRefresh: () {},
            onRecenter: () {},
          ),
        ),
      );
      expect(find.byIcon(Icons.route), findsOneWidget); // filled = loaded
      expect(find.text('あ'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byIcon(Icons.location_searching), findsOneWidget);
      // Badge hidden at zero.
      expect(find.text('0'), findsNothing);
    });
  });

  group('AssetDebugSheet', () {
    testWidgets('shows the live report; copy confirms with a snackbar', (
      t,
    ) async {
      final monitor = AssetMonitor();
      final client = MonitoredClient(
        MockClient((_) async => http.Response('x' * 1000, 200)),
        monitor,
      );
      // Real-async island: stream futures never resolve under the fake-async
      // zone, and the extra delay lets the monitor's coalescing timer fire
      // here rather than leak into the fake clock.
      await t.runAsync(() async {
        await client.get(
          Uri.parse(
            'https://a.tile-cyclosm.openstreetmap.fr/cyclosm/6/56/25.png',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });

      await t.pumpWidget(
        _host(
          AssetDebugSheet(
            monitor: monitor,
            snapshot: () => const DebugScreenState(
              closureCount: 3,
              translatorStatus: 'ready',
            ),
          ),
        ),
      );

      expect(find.textContaining('ASSET DEBUG'), findsOneWidget);
      expect(find.textContaining('Base map tiles'), findsOneWidget);
      expect(find.textContaining('z6  ok 1'), findsOneWidget);
      expect(find.textContaining('closures      3 shown'), findsOneWidget);

      await t.tap(find.byIcon(Icons.copy));
      await t.pump();
      expect(find.text('Report copied'), findsOneWidget);
      // Fixed-duration pumps, not pumpAndSettle: the sheet's periodic repaint
      // timer keeps scheduling frames, so settle would spin forever. 5 s
      // covers the snackbar's auto-hide, 1 s its exit animation.
      await t.pump(const Duration(seconds: 5));
      await t.pump(const Duration(seconds: 1));

      // Dispose the sheet so its periodic repaint timer is cancelled.
      await t.pumpWidget(const SizedBox());
      monitor.dispose();
    });
  });

  group('FrameControls', () {
    const frames = [
      JmaFrame(
        basetime: '20260716000000',
        validtime: '20260716000000',
        offsetMin: 0,
      ),
      JmaFrame(
        basetime: '20260716000000',
        validtime: '20260716003000',
        offsetMin: 30,
      ),
    ];

    testWidgets('no frames: spinner shown, controls disabled', (t) async {
      await t.pumpWidget(
        _host(
          FrameControls(
            frames: const [],
            frameIndex: 0,
            frameStatus: const [],
            playing: true,
            onPlayPause: () => fail('disabled'),
            onSeek: (_) => fail('disabled'),
          ),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await t.tap(find.byIcon(Icons.pause), warnIfMissed: false);
    });

    testWidgets('labels show JST time and forecast offset; play/pause fires', (
      t,
    ) async {
      var toggled = 0;
      await t.pumpWidget(
        _host(
          FrameControls(
            frames: frames,
            frameIndex: 1,
            frameStatus: const [FrameLoadState.loaded, FrameLoadState.loaded],
            playing: false,
            onPlayPause: () => toggled++,
            onSeek: (_) {},
          ),
        ),
      );
      // 00:30 UTC -> 09:30 JST; offset +30 is a forecast.
      expect(find.text('09:30 JST'), findsOneWidget);
      expect(find.text('forecast +30m'), findsOneWidget);
      await t.tap(find.byIcon(Icons.play_arrow));
      expect(toggled, 1);
    });

    testWidgets('per-frame dots take their load-state colour', (t) async {
      await t.pumpWidget(
        _host(
          FrameControls(
            frames: frames,
            frameIndex: 0,
            frameStatus: const [FrameLoadState.loaded, FrameLoadState.failed],
            playing: false,
            onPlayPause: () {},
            onSeek: (_) {},
          ),
        ),
      );
      Color dot(int i) {
        final c = t.widget<Container>(find.byKey(ValueKey('frame-dot-$i')));
        return (c.decoration! as BoxDecoration).color!;
      }

      expect(dot(0), FrameControls.statusColor(FrameLoadState.loaded));
      expect(dot(1), FrameControls.statusColor(FrameLoadState.failed));
    });
  });

  group('RadarLegend', () {
    testWidgets('shows the JMA intensity scale', (t) async {
      await t.pumpWidget(_host(const RadarLegend()));
      expect(find.text('mm/h'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
      expect(find.text('80+'), findsOneWidget);
    });
  });

  group('TranslationController.prefersEnglish', () {
    test('Japanese OS locales start untranslated, everything else English', () {
      expect(TranslationController.prefersEnglish(const Locale('ja')), false);
      expect(
        TranslationController.prefersEnglish(const Locale('ja', 'JP')),
        false,
      );
      expect(
        TranslationController.prefersEnglish(const Locale('en', 'US')),
        true,
      );
      expect(TranslationController.prefersEnglish(const Locale('de')), true);
    });
  });

  group('TileStatusMonitor', () {
    test('counts distinct failures, ignores radar 404s, resets', () {
      final m = TileStatusMonitor();
      var notifications = 0;
      m.addListener(() => notifications++);

      m.recordError('base', const TileCoordinates(1, 2, 8), Exception('boom'));
      m.recordError('base', const TileCoordinates(1, 2, 8), Exception('boom'));
      expect(m.failedCount, 1, reason: 'same tile counted once');
      expect(notifications, 1);

      m.recordError('radar', const TileCoordinates(1, 2, 8), Exception('x'));
      expect(m.failedCount, 2, reason: 'same coords, different layer');

      m.recordError(
        'radar',
        const TileCoordinates(3, 4, 8),
        Exception('HTTP request failed, statusCode: 404, https://jma'),
      );
      expect(m.failedCount, 2, reason: 'rain-free 404s are expected');

      m.reset();
      expect(m.hasFailures, isFalse);
      expect(notifications, 3); // add, add, reset
    });
  });

  group('failed-tiles banner', () {
    testWidgets('shows count and fires retry on tap; hidden while offline', (
      t,
    ) async {
      var retried = 0;
      await t.pumpWidget(
        _host(
          MapBanners(
            offline: false,
            english: false,
            translatorStatus: TranslatorStatus.idle,
            translatorError: null,
            downloadStartedAt: null,
            translating: false,
            radarError: null,
            locationError: null,
            closuresError: null,
            failedTileCount: 4,
            onRetryTiles: () => retried++,
          ),
        ),
      );
      expect(find.textContaining('4 map tiles failed'), findsOneWidget);
      await t.tap(find.textContaining('4 map tiles failed'));
      expect(retried, 1);

      // Offline supersedes: the offline banner already explains everything.
      await t.pumpWidget(_host(_banners(offline: true)));
      expect(find.textContaining('failed to load'), findsNothing);
    });
  });

  group('dismissable error banners', () {
    testWidgets('the offline × reports which banner was dismissed', (t) async {
      final dismissed = <MapBanner>[];
      await t.pumpWidget(
        _host(
          MapBanners(
            offline: true,
            offlineDismissed: false,
            english: false,
            translatorStatus: TranslatorStatus.idle,
            translatorError: null,
            downloadStartedAt: null,
            translating: false,
            radarError: null,
            locationError: null,
            closuresError: null,
            onDismiss: dismissed.add,
          ),
        ),
      );
      expect(find.byTooltip('Dismiss'), findsOneWidget);
      await t.tap(find.byTooltip('Dismiss'));
      expect(dismissed, [MapBanner.offline]);
    });

    testWidgets('online, each source failure gets its own ×', (t) async {
      final dismissed = <MapBanner>[];
      await t.pumpWidget(
        _host(
          MapBanners(
            offline: false,
            english: false,
            translatorStatus: TranslatorStatus.idle,
            translatorError: null,
            downloadStartedAt: null,
            translating: false,
            radarError: 'boom',
            locationError: 'no gps',
            closuresError: 'JARTIC: down',
            onDismiss: dismissed.add,
          ),
        ),
      );
      // radar, location, closures each dismissable.
      expect(find.byTooltip('Dismiss'), findsNWidgets(3));
    });

    testWidgets('no × when onDismiss is not wired', (t) async {
      await t.pumpWidget(_host(_banners(radarError: 'boom')));
      expect(find.byTooltip('Dismiss'), findsNothing);
    });

    testWidgets('a dismissed offline banner hides but keeps tiles suppressed', (
      t,
    ) async {
      await t.pumpWidget(
        _host(
          MapBanners(
            offline: true,
            offlineDismissed: true,
            english: false,
            translatorStatus: TranslatorStatus.idle,
            translatorError: null,
            downloadStartedAt: null,
            translating: false,
            radarError: null,
            locationError: null,
            closuresError: null,
            failedTileCount: 3,
            onDismiss: (_) {},
          ),
        ),
      );
      // Connectivity banner gone, and the tiles banner stays hidden (offline).
      expect(find.textContaining('No connection'), findsNothing);
      expect(find.textContaining('failed to load'), findsNothing);
    });
  });

  group('MapCompass', () {
    testWidgets('hidden when the map faces north', (t) async {
      await t.pumpWidget(_host(MapCompass(rotationDeg: 0, onFaceNorth: () {})));
      expect(find.byType(FloatingActionButton), findsNothing);
    });

    testWidgets('appears when rotated and tapping faces north', (t) async {
      var faced = 0;
      await t.pumpWidget(
        _host(MapCompass(rotationDeg: 45, onFaceNorth: () => faced++)),
      );
      expect(find.byTooltip('Face north'), findsOneWidget);
      await t.tap(find.byTooltip('Face north'));
      expect(faced, 1);
    });

    test('offNorth folds any bearing into 0..180 from north', () {
      expect(MapCompass.offNorth(0), 0);
      expect(MapCompass.offNorth(90), 90);
      expect(MapCompass.offNorth(180), 180);
      expect(MapCompass.offNorth(270), 90);
      expect(MapCompass.offNorth(359), closeTo(1, 1e-9));
      expect(MapCompass.offNorth(-90), 90); // negative bearings normalise
    });
  });

  group('radar zoom settle', () {
    // The radar layers pin their fetch level (min == max native zoom); the
    // base layer doesn't, so this picks out just the radar grids.
    List<int> radarLevels(WidgetTester t) => [
      for (final l in t.widgetList<TileLayer>(find.byType(TileLayer)))
        if (l.minNativeZoom == l.maxNativeZoom) l.minNativeZoom,
    ];

    testWidgets('radar layers re-key to the new level only after the zoom '
        'holds still, mounting the active frame first', (t) async {
      final controller = await pumpMap(t);
      // Staged mounting: only the visible frame's layer fetches at first,
      // so its tiles aren't queued behind the preload frames'.
      expect(radarLevels(t), [10]);
      await t.pump(const Duration(seconds: 2));
      expect(radarLevels(t), [10, 10]);

      // Mid-gesture: the camera has crossed to a lower level, but the grids
      // must keep serving z10 until the zoom settles.
      controller.move(const LatLng(35, 137), 5.9);
      await t.pump();
      expect(radarLevels(t), [10, 10]);

      // Held still past the settle delay: the switch happens - active frame
      // first again, the preload following.
      await t.pump(const Duration(milliseconds: 300));
      expect(radarLevels(t), [6]);
      await t.pump(const Duration(seconds: 2));
      expect(radarLevels(t), [6, 6]);

      // Drain the base layer's debounced tile update before teardown.
      await t.pump(const Duration(milliseconds: 300));
    });

    testWidgets('a crossing the gesture reverses out of never re-keys', (
      t,
    ) async {
      final controller = await pumpMap(t);
      await t.pump(const Duration(seconds: 2)); // both frames mounted

      controller.move(const LatLng(35, 137), 5.9);
      await t.pump(const Duration(milliseconds: 100));
      controller.move(const LatLng(35, 137), 10); // pinch back in
      await t.pump(const Duration(milliseconds: 400));
      // Never re-keyed - and the mounted set survived untouched.
      expect(radarLevels(t), [10, 10]);

      await t.pump(const Duration(milliseconds: 300));
    });
  });

  group('attribution', () {
    testWidgets('the (i) opens the credits centred on screen, not in the '
        'corner', (t) async {
      final opened = <Uri>[];
      await pumpMap(t, opened: opened);

      await t.tap(find.byTooltip('Map credits'));
      await t.pumpAndSettle();

      final dialog = find.byType(SimpleDialog);
      expect(dialog, findsOneWidget);
      // Centred: the dialog's middle coincides with the 800×600 test
      // surface's middle, so it can't be hiding behind the corner FABs.
      expect(t.getCenter(dialog).dx, closeTo(400, 1));
      expect(t.getCenter(dialog).dy, closeTo(300, 1));

      // All four credits, with the Japanese-mode base map named (including
      // the OSM France hosting credit), plus the standing disclaimer.
      expect(find.text('JMA Weather (processed)'), findsOneWidget);
      expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
      expect(
        find.text('CyclOSM · tiles hosted by OpenStreetMap France'),
        findsOneWidget,
      );
      expect(
        find.textContaining('never means that a road is open'),
        findsOneWidget,
      );

      await t.tap(find.textContaining('CyclOSM'));
      expect(opened, [Uri.parse('https://www.cyclosm.org')]);

      // Drain the radar layers' staged-mount timer before teardown.
      await t.pump(const Duration(seconds: 2));
    });
  });

  group('place taps', () {
    // The pin used to clear itself on tap; it now opens a menu (weather, or
    // clear). If the gesture is ever lost in a refactor the pin becomes
    // undismissable and the weather unreachable, with nothing else to say so.
    // pumpMap's initial centre, so the marker lands mid-screen where it can
    // actually be tapped.
    const spot = LatLng(35, 137);

    testWidgets('tapping the pin reports the pinned spot', (t) async {
      final places = <(LatLng, bool)>[];
      await pumpMap(t, pin: spot, places: places);
      await t.pumpAndSettle();

      await t.tap(find.byIcon(Icons.place));
      await t.pumpAndSettle();
      expect(places, [(spot, true)]);
    });

    testWidgets('tapping the rider dot reports it as unpinned', (t) async {
      final places = <(LatLng, bool)>[];
      await pumpMap(t, rider: spot, places: places);
      await t.pumpAndSettle();

      // The dot has no icon to find; it's the only marker on the map.
      await t.tap(find.byType(MarkerLayer));
      await t.pumpAndSettle();
      expect(places, [(spot, false)]);
    });
  });

  group('first-run disclaimer', () {
    testWidgets('blocks until acknowledged, then never shows again', (t) async {
      SharedPreferences.setMockInitialValues({});
      late BuildContext ctx;
      await t.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (c) {
              ctx = c;
              return const SizedBox();
            },
          ),
        ),
      );

      final shown = showFirstRunDisclaimer(ctx);
      await t.pumpAndSettle();
      expect(find.text('Before you ride'), findsOneWidget);
      expect(find.textContaining('Obey the road signs'), findsOneWidget);
      // barrierDismissible: false - tapping outside must not dismiss it.
      await t.tapAt(const Offset(5, 5));
      await t.pumpAndSettle();
      expect(find.text('Before you ride'), findsOneWidget);

      await t.tap(find.text('I understand'));
      await t.pumpAndSettle();
      await shown;
      expect(find.text('Before you ride'), findsNothing);

      // Acknowledged: the next launch stays quiet.
      await showFirstRunDisclaimer(ctx);
      await t.pumpAndSettle();
      expect(find.text('Before you ride'), findsNothing);
    });
  });
}
