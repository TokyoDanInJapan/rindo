import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:rindo/closures/closure_repository.dart';
import 'package:rindo/closures/road_closure.dart';
import 'package:rindo/closures/seasonal_gates.dart';
import 'package:rindo/screens/radar_map/closures_controller.dart';
import 'package:rindo/translate/closure_translator.dart';

/// The controller is the app's logic hub; these tests pin the refresh
/// gating, the rider/pin/route precedence, partial-source degradation, the
/// translation swap-in, and dispose safety.

const _home = LatLng(36.0, 138.0); // in Nagano's bbox → JARTIC tile R20

/// A JARTIC tile with one closure 1.5 km from [_home]; MLIT empty.
/// [onTarget] is called for every JARTIC index fetch - a fetch counter.
http.Client _fakeLive({void Function()? onTarget}) => MockClient((req) async {
  final path = req.url.path;
  if (path.contains('/landslide/map.json')) {
    return http.Response('[]', 200); // no active landslide alerts
  }
  if (path.endsWith('/target.json')) {
    onTarget?.call();
    return http.Response('{"target":"202607170900"}', 200);
  }
  if (path.contains('/d/301/R20.json')) {
    return http.Response.bytes(
      utf8.encode(
        '{"type":"FeatureCollection","features":[{"type":"Feature",'
        '"properties":{"cs":"01","rd":"通行止","r":"県道８４号",'
        '"c":"土砂崩落","p":[[138.005,36.01]],"rn":"x1"},'
        '"geometry":{"type":"LineString",'
        '"coordinates":[[138.005,36.01],[138.01,36.015]]}}]}',
      ),
      200,
    );
  }
  if (path.contains('/d/301/')) {
    return http.Response('{"type":"FeatureCollection","features":[]}', 200);
  }
  if (path.contains('pcTukokisei_')) {
    return http.Response('no backup path here', 200);
  }
  return http.Response('not found', 404);
});

/// Deterministic, no platform channels: instantly "translates" by prefixing.
class _FakeTranslator extends ClosureTranslator {
  @override
  Future<bool> ensureReady() async => true;

  @override
  Future<RoadClosure> translateClosure(RoadClosure c) async => RoadClosure(
    id: c.id,
    point: c.point,
    roadName: 'EN:${c.roadName}',
    restriction: c.restriction,
    sourceName: c.sourceName,
    sourceUrl: c.sourceUrl,
    isFullClosure: c.isFullClosure,
  );
}

class _Clock {
  DateTime now = DateTime(2026, 7, 17, 9, 0);
  void advance(Duration d) => now = now.add(d);
}

(ClosuresController, _Clock, List<int>) _build({
  http.Client? client,
  ClosureTranslator? translator,
  bool japanese = true,
}) {
  final clock = _Clock();
  final fetches = <int>[];
  final controller = ClosuresController(
    vsync: const TestVSync(),
    repository: ClosureRepository(
      client: client ?? _fakeLive(onTarget: () => fetches.add(1)),
      // No bundled gates: tests control exactly what data exists.
      seasonal: SeasonalGateSource(gates: const [], now: () => clock.now),
      now: () => clock.now,
    ),
    translator: translator,
    now: () => clock.now,
  );
  // Default is English; most tests run in Japanese so the (real, platform-
  // channel-backed) translator is never exercised.
  if (japanese && translator == null) controller.toggleLanguage();
  return (controller, clock, fetches);
}

void main() {
  // The controller drives an AnimationController (the ring pulse), which
  // needs the scheduler binding even under plain test().
  TestWidgetsFlutterBinding.ensureInitialized();

  test('first GPS fix fetches closures around the rider', () async {
    final (c, _, fetches) = _build();
    c.setRider(_home);
    await pumpEventQueue();
    expect(fetches, hasLength(1));
    expect(c.shown, hasLength(1));
    expect(c.shown.single.roadName, '県道８４号');
    expect(c.searchCenter, _home);
  });

  test('refresh is gated: small move within 15 min does not refetch, '
      'a >10 km move or stale data does', () async {
    final (c, clock, fetches) = _build();
    c.setRider(_home);
    await pumpEventQueue();
    expect(fetches, hasLength(1));

    // 1 km north, 1 min later: gated.
    clock.advance(const Duration(minutes: 1));
    c.setRider(const LatLng(36.009, 138.0));
    await pumpEventQueue();
    expect(fetches, hasLength(1));

    // ~15 km north: refetch.
    c.setRider(const LatLng(36.135, 138.0));
    await pumpEventQueue();
    expect(fetches, hasLength(2));

    // Same place, 16 minutes later: age triggers refetch.
    clock.advance(const Duration(minutes: 16));
    c.setRider(const LatLng(36.136, 138.0));
    await pumpEventQueue();
    expect(fetches, hasLength(3));
  });

  test('pin overrides rider; clearing returns to the rider', () async {
    final (c, _, fetches) = _build();
    c.setRider(_home);
    await pumpEventQueue();

    const pin = LatLng(35.5, 137.5);
    c.dropPin(pin);
    await pumpEventQueue();
    expect(c.pinned, isTrue);
    expect(c.searchCenter, pin);
    expect(fetches, hasLength(2)); // pin drop always refetches

    c.clearPin();
    await pumpEventQueue();
    expect(c.pinned, isFalse);
    expect(c.searchCenter, _home);
  });

  test(
    'route mode: owns the search, clears the pin, drops distances',
    () async {
      final (c, _, _) = _build();
      c.setRider(_home);
      c.dropPin(const LatLng(35.5, 137.5));
      await pumpEventQueue();

      c.loadRoute([_home, const LatLng(36.05, 138.0)]);
      await pumpEventQueue();
      expect(c.routeMode, isTrue);
      expect(c.pinned, isFalse, reason: 'route replaces the pin');
      expect(c.distanceCenter, isNull, reason: 'no point distances on a route');
      expect(c.activeRadiusKm, ClosuresController.routeRadiusKm);
      // The fixture closure is ~1.5 km off the route: inside the corridor.
      expect(c.shown, hasLength(1));

      c.clearRoute();
      await pumpEventQueue();
      expect(c.routeMode, isFalse);
      expect(c.activeRadiusKm, ClosuresController.pointRadiusKm);
      expect(c.distanceCenter, _home);
    },
  );

  test('a dead live source degrades to partial data plus an error', () async {
    final clock = _Clock();
    final gate = SeasonalGate(
      id: 'test',
      roadName: '県道1号',
      section: 'A～B',
      lat: 36.01,
      lon: 138.0,
      closesMonth: 11,
      closesDay: 15,
      opensMonth: 4,
      opensDay: 20,
      sourceUrl: 'https://example.com',
    );
    final c = ClosuresController(
      vsync: const TestVSync(),
      repository: ClosureRepository(
        client: MockClient((_) async => throw http.ClientException('no net')),
        seasonal: SeasonalGateSource(gates: [gate], now: () => clock.now),
        now: () => clock.now,
      ),
      now: () => clock.now,
    )..toggleLanguage(); // Japanese: no translator involvement
    c.setRider(_home);
    await pumpEventQueue();
    expect(c.shown.map((r) => r.id), contains('seasonal-test'));
    expect(c.error, contains('JARTIC'));
  });

  test('English mode swaps in translated copies; toggling back restores '
      'the originals', () async {
    final (c, _, _) = _build(translator: _FakeTranslator(), japanese: false);
    expect(c.english, isTrue); // the default
    c.setRider(_home);
    await pumpEventQueue();
    expect(c.shown.single.roadName, 'EN:県道８４号');

    c.toggleLanguage(); // Japanese: originals, immediately
    expect(c.english, isFalse);
    expect(c.shown.single.roadName, '県道８４号');
  });

  test(
    'dispose during an in-flight fetch neither throws nor notifies',
    () async {
      final (c, _, _) = _build();
      c.setRider(_home);
      final inFlight = c.refresh(force: true);
      c.dispose();
      await inFlight; // the guarded finally must not touch disposed objects
      await pumpEventQueue();
    },
  );
}
