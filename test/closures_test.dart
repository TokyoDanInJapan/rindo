import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:rindo/closures/closure_repository.dart';
import 'package:rindo/closures/jartic_source.dart';
import 'package:rindo/closures/mlit_source.dart';
import 'package:rindo/closures/prefectures.dart';
import 'package:rindo/closures/road_closure.dart';
import 'package:rindo/closures/search_area.dart';

// Fixtures are real responses captured from both services on 2026-07-13.
final _r13 = File('test/fixtures/r13.json').readAsStringSync();
final _tuko83 = File('test/fixtures/tuko83.json').readAsStringSync();

const _shinjuku = LatLng(35.69, 139.70);

http.Client _fake() => MockClient(_fakeResponse);

Future<http.Response> _fakeResponse(http.Request req) async {
  final path = req.url.path;
  if (path.contains('/landslide/map.json')) {
    return http.Response('[]', 200); // no active landslide alerts
  }
  if (path.endsWith('/target.json')) {
    return http.Response('{"target":"202607132302"}', 200);
  }
  if (path.contains('/d/301/R13.json')) {
    // Response.bytes: the plain constructor latin1-encodes, which throws
    // on the Japanese text in the fixture.
    return http.Response.bytes(utf8.encode(_r13), 200);
  }
  if (path.contains('/d/301/')) {
    // Other prefecture tiles: empty collections.
    return http.Response('{"type":"FeatureCollection","features":[]}', 200);
  }
  if (path.contains('pcTukokisei_83_1.html')) {
    return http.Response(
      '<script src="../backup/20260713225000/wWlvF7lrVqgihhfH/init.js">'
      '</script>',
      200,
    );
  }
  if (path.contains('pcTukokisei_')) {
    // A live data path; its category files 404, which reads as empty.
    return http.Response(
      '<script src="../backup/20260713225000/x/init.js">',
      200,
    );
  }
  if (path.contains('/TukoKisei/83.json')) {
    return http.Response.bytes(utf8.encode(_tuko83), 200);
  }
  if (path.contains('/TokiTuko/')) {
    return http.Response.bytes(utf8.encode('{"13_東京都":[]}'), 200);
  }
  return http.Response('not found', 404);
}

void main() {
  test('prefecture lookup includes neighbours within the radius', () {
    final codes = prefecturesNear(_shinjuku, 50).map((p) => p.code).toSet();
    expect(codes, contains('13')); // Tokyo
    expect(codes, contains('11')); // Saitama
    expect(codes, contains('14')); // Kanagawa
    expect(codes, isNot(contains('27'))); // Osaka is 400 km away
  });

  test(
    'JARTIC keeps only full closures, with geometry and source link',
    () async {
      final result = await JarticSource(
        _fake(),
      ).fetch(CircleArea(_shinjuku, 50));
      expect(result.problems, isEmpty);
      final closures = result.closures;
      expect(closures, hasLength(3)); // 3 通行止 among 370 R13 regulations
      for (final c in closures) {
        expect(c.restriction, contains('通行止'));
        expect(c.isFullClosure, isTrue);
        expect(c.distanceKmFrom(_shinjuku), lessThanOrEqualTo(50));
        expect(c.lines, isNotEmpty);
        expect(c.sourceUrl.toString(), contains('jartic.or.jp/map'));
      }
      expect(closures.map((c) => c.roadName), contains('文京区道'));
    },
  );

  test('MLIT resolves the backup path and keeps only 通行止 records', () async {
    // 国道16号 closure in the fixture sits near Yokohama.
    final result = await MlitSource(
      _fake(),
    ).fetch(CircleArea(const LatLng(35.45, 139.55), 50));
    expect(result.problems, isEmpty);
    final closures = result.closures;
    expect(closures, hasLength(2)); // 2 通行止 among 130 Kanto regulations
    final r16 = closures.firstWhere((c) => c.roadName == '国道16号');
    expect(r16.period, contains('2026'));
    expect(r16.lines, isNotEmpty);
    expect(r16.sourceUrl.toString(), contains('pcTukokisei_83_1.html'));
  });

  test('a JARTIC tile that fails falls back to the last good copy and says '
      'so', () async {
    var tileUp = true;
    final source = JarticSource(
      MockClient((req) async {
        if (!tileUp && req.url.path.contains('/d/301/R13.json')) {
          return http.Response('busy', 503);
        }
        return _fakeResponse(req);
      }),
    );
    final area = CircleArea(_shinjuku, 50);
    final first = await source.fetch(area);
    expect(first.closures, hasLength(3));

    tileUp = false;
    final second = await source.fetch(area);
    expect(second.closures, hasLength(3));
    expect(second.problems.single, contains('showing the last data received'));
  });

  test('an MLIT page with no data path is reported, not read as "no '
      'closures"', () async {
    final result = await MlitSource(
      MockClient((_) async => http.Response('redesigned page', 200)),
    ).fetch(CircleArea(const LatLng(35.45, 139.55), 50));
    expect(result.closures, isEmpty);
    expect(result.problems.single, contains('unavailable'));
  });

  test(
    'repository merges sources and drops JARTIC duplicates of MLIT roads',
    () async {
      final repo = ClosureRepository(client: _fake());
      // Around Yokohama both sources are in range; the fixture sets don't
      // overlap on the same road+location, so everything survives the dedupe.
      final (closures, errors) = await repo.fetchNear(
        const LatLng(35.55, 139.65),
        50,
      );
      expect(errors, isEmpty);
      final ids = closures.map((c) => c.id).toSet();
      expect(ids.length, closures.length);
      expect(closures.where((c) => c.id.startsWith('mlit-')), isNotEmpty);
      expect(closures.where((c) => c.id.startsWith('jartic-')), isNotEmpty);
    },
  );

  test('fetchAlong finds closures in the route corridor, not off it', () async {
    final repo = ClosureRepository(client: _fake());
    // A route through Tokyo (where R13 has the fixture closures). The
    // corridor is 10 km; the fixtures sit near Shinjuku.
    final (onRoute, _) = await repo.fetchAlong([
      const LatLng(35.69, 139.70),
      const LatLng(35.66, 139.75),
    ], 10);
    expect(onRoute.where((c) => c.id.startsWith('jartic-')), isNotEmpty);

    // A route far out in the Pacific hits no prefecture tiles at all.
    final (offRoute, _) = await repo.fetchAlong([
      const LatLng(33.0, 145.0),
      const LatLng(33.1, 145.1),
    ], 10);
    expect(offRoute, isEmpty);
  });

  test('dedupe collapses same national road within 5 km', () {
    final repo = ClosureRepository(client: _fake());
    // ignore: invalid_use_of_visible_for_testing_member
    final mlit = RoadClosure(
      id: 'mlit-1',
      point: const LatLng(35.4978, 139.4935),
      roadName: '国道16号',
      restriction: '通行止',
      sourceName: 'MLIT',
      sourceUrl: Uri.parse('https://example.com'),
    );
    final jarticDup = RoadClosure(
      id: 'jartic-1',
      point: const LatLng(35.4990, 139.4990),
      roadName: '国道１６号', // full-width digits, as JARTIC serves them
      restriction: '通行止',
      sourceName: 'JARTIC',
      sourceUrl: Uri.parse('https://example.com'),
    );
    expect(repo.debugIsDuplicate(jarticDup, [mlit]), isTrue);

    final different = RoadClosure(
      id: 'jartic-2',
      point: const LatLng(35.4990, 139.4990),
      roadName: '国道３５７号',
      restriction: '通行止',
      sourceName: 'JARTIC',
      sourceUrl: Uri.parse('https://example.com'),
    );
    expect(repo.debugIsDuplicate(different, [mlit]), isFalse);
  });

  test('an MLIT record without start, end or dates has no section or '
      'period, rather than empty ones', () async {
    final result = await MlitSource(
      MockClient((req) async {
        if (req.url.path.contains('pcTukokisei_')) {
          return http.Response(
            '<script src="../backup/20260713225000/x/a.js">',
            200,
          );
        }
        if (req.url.path.contains('/TukoKisei/83.json')) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode({
                '14_神奈川県': [
                  {
                    'kisei_naiyo_cd': '01',
                    'kisei_meisho': '通行止',
                    'rosen_name': '国道16号',
                    'kisei_kaishi_chiten': ' ',
                    'iconData': {
                      'point': ['139.55', '35.45'],
                    },
                  },
                ],
              }),
            ),
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    ).fetch(CircleArea(const LatLng(35.45, 139.55), 10));
    final c = result.closures.single;
    expect(c.section, isNull);
    expect(c.period, isNull);
  });

  test("Tokyo's islands no longer pull R13 into searches around Nagoya, "
      'but Ogasawara still gets it', () {
    List<String> codes(LatLng p) =>
        prefecturesNear(p, 50).map((p) => p.code).toList();
    expect(codes(const LatLng(35.18, 136.91)), isNot(contains('13')));
    expect(codes(const LatLng(27.09, 142.19)), ['13']);
    expect(codes(_shinjuku).where((c) => c == '13'), hasLength(1));
  });
}
