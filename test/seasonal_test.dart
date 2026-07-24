import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:rindo/closures/closure_repository.dart';
import 'package:rindo/closures/road_closure.dart';
import 'package:rindo/closures/seasonal_gates.dart';

// A pass in Nagano that nominally closes Nov 15 and reopens Apr 20.
const _gate = SeasonalGate(
  id: 'test-pass',
  roadName: '県道84号（テスト峠）',
  section: 'A～B',
  lat: 36.0,
  lon: 138.0,
  closesMonth: 11,
  closesDay: 15,
  opensMonth: 4,
  opensDay: 20,
  sourceUrl: 'https://example.com/winter',
);

const _nearGate = LatLng(36.01, 138.01);

/// JARTIC reports a live closure on the same road, 1.5 km from the gate.
/// MLIT responds with nothing.
http.Client _fakeLive() => MockClient((req) async {
  final path = req.url.path;
  if (path.contains('/landslide/map.json')) {
    return http.Response('[]', 200); // no active landslide alerts
  }
  if (path.endsWith('/target.json')) {
    return http.Response('{"target":"202607140900"}', 200);
  }
  if (path.contains('/d/301/R20.json')) {
    // Response.bytes: the plain constructor latin1-encodes, which throws
    // on the Japanese property values.
    return http.Response.bytes(
      utf8.encode(
        '{"type":"FeatureCollection","features":[{"type":"Feature",'
        '"properties":{"cs":"01","rd":"通行止","r":"県道８４号","c":"土砂崩落",'
        '"p":[[138.005,36.01]],"rn":"x1"},'
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

ClosureRepository _repo(DateTime now) => ClosureRepository(
  client: _fakeLive(),
  seasonal: SeasonalGateSource(gates: const [_gate], now: () => now),
  now: () => now,
);

void main() {
  group('window materialisation', () {
    test('summer: next window is this Nov → next Apr, status scheduled', () {
      final now = DateTime(2026, 7, 14);
      final (from, until) = SeasonalGateSource.windowAt(_gate, now);
      expect(from, DateTime(2026, 11, 15));
      expect(until, DateTime(2027, 4, 20));

      final c = SeasonalGateSource(gates: const [_gate], now: () => now);
      expect(
        c.fetchNear(_nearGate, 50),
        completion([
          predicate<RoadClosure>(
            (r) => r.statusAt(now) == ClosureStatus.scheduled,
          ),
        ]),
      );
    });

    test('mid-winter: inside the window, status active', () {
      final now = DateTime(2027, 1, 10);
      final (from, until) = SeasonalGateSource.windowAt(_gate, now);
      expect(from, DateTime(2026, 11, 15));
      expect(until, DateTime(2027, 4, 20));

      final gate = RoadClosure(
        id: 's',
        point: _nearGate,
        roadName: 'x',
        restriction: '冬期通行止',
        sourceName: 's',
        sourceUrl: Uri.parse('https://example.com'),
        validFrom: from,
        validUntil: until,
        isSeasonal: true,
      );
      expect(gate.statusAt(now), ClosureStatus.active);
    });

    test('just after reopening: rolls over to the next season', () {
      final (from, until) = SeasonalGateSource.windowAt(
        _gate,
        DateTime(2026, 4, 25),
      );
      expect(from, DateTime(2026, 11, 15));
      expect(until, DateTime(2027, 4, 20));
    });
  });

  test('gates outside the search radius are not returned', () async {
    final source = SeasonalGateSource(
      gates: const [_gate],
      now: () => DateTime(2026, 7, 14),
    );
    expect(await source.fetchNear(const LatLng(34.7, 135.5), 50), isEmpty);
    expect(await source.fetchNear(_nearGate, 50), hasLength(1));
  });

  test('bundled dataset materialises against today without errors', () async {
    // 渋峠 gate is in the bundled data; search around Kusatsu.
    final all = await SeasonalGateSource().fetchNear(
      const LatLng(36.62, 138.60),
      50,
    );
    expect(all.map((c) => c.id), contains('seasonal-r292-shibu'));
    for (final c in all) {
      expect(c.isSeasonal, isTrue);
      expect(c.validFrom!.isBefore(c.validUntil!), isTrue);
    }
  });

  test('every bundled gate ships road geometry near its point', () async {
    // Far-north center + huge radius = the whole country; every curated gate
    // must come back with generated lines that hug its own coordinates.
    final all = await SeasonalGateSource().fetchNear(
      const LatLng(38, 138),
      500,
    );
    expect(all, hasLength(seasonalGates.length));
    for (final c in all) {
      expect(c.lines, isNotEmpty, reason: '${c.id} has no geometry');
      const dist = Distance();
      final nearest = [
        for (final line in c.lines)
          for (final p in line) dist.as(LengthUnit.Kilometer, c.point, p),
      ].reduce((a, b) => a < b ? a : b);
      expect(nearest, lessThan(5), reason: '${c.id} geometry far from gate');
    }
  });

  group('repository precedence', () {
    test('live duplicate of an ACTIVE gate is dropped (gate wins)', () async {
      final (closures, _) = await _repo(
        DateTime(2027, 1, 10),
      ).fetchNear(_nearGate, 50);
      expect(closures.map((c) => c.id), contains('seasonal-test-pass'));
      expect(closures.where((c) => c.id.startsWith('jartic-')), isEmpty);
    });

    test('live closure on the same road survives while the gate is only '
        'scheduled', () async {
      final (closures, errors) = await _repo(
        DateTime(2026, 7, 14),
      ).fetchNear(_nearGate, 50);
      expect(errors, isEmpty);
      expect(closures.map((c) => c.id), contains('seasonal-test-pass'));
      expect(closures.where((c) => c.id.startsWith('jartic-')), hasLength(1));
    });
  });

  test('a dead live source degrades to bundled data plus an error, not an '
      'empty list', () async {
    // Every network request fails at the socket level (offline).
    final repo = ClosureRepository(
      client: MockClient((_) async => throw http.ClientException('no net')),
      seasonal: SeasonalGateSource(
        gates: const [_gate],
        now: () => DateTime(2026, 7, 14),
      ),
      now: () => DateTime(2026, 7, 14),
    );
    final (closures, errors) = await repo.fetchNear(_nearGate, 50);
    expect(closures.map((c) => c.id), contains('seasonal-test-pass'));
    // JARTIC's index fetch and the landslide feed both fail over the dead
    // network; MLIT self-degrades internally.
    expect(errors, hasLength(2));
    expect(errors.join(), contains('JARTIC'));
    expect(errors.join(), contains('土砂災害警戒情報'));
  });

  test('route classes do not cross-match: 国道84号 is not 県道84号', () {
    final repo = ClosureRepository(client: _fakeLive());
    final kendo = RoadClosure(
      id: 'a',
      point: const LatLng(36.0, 138.0),
      roadName: '県道84号',
      restriction: '通行止',
      sourceName: 's',
      sourceUrl: Uri.parse('https://example.com'),
    );
    final kokudo = RoadClosure(
      id: 'b',
      point: const LatLng(36.001, 138.001),
      roadName: '国道84号',
      restriction: '通行止',
      sourceName: 's',
      sourceUrl: Uri.parse('https://example.com'),
    );
    final fullWidthKendo = RoadClosure(
      id: 'c',
      point: const LatLng(36.001, 138.001),
      roadName: '長野県道８４号乗鞍岳線',
      restriction: '通行止',
      sourceName: 's',
      sourceUrl: Uri.parse('https://example.com'),
    );
    // ignore: invalid_use_of_visible_for_testing_member
    expect(repo.debugIsDuplicate(kokudo, [kendo]), isFalse);
    // ignore: invalid_use_of_visible_for_testing_member
    expect(repo.debugIsDuplicate(fullWidthKendo, [kendo]), isTrue);
  });
}
