import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:rindo/closures/closure_repository.dart';
import 'package:rindo/closures/seasonal_gates.dart';
import 'package:rindo/hazards/landslide_source.dart';

/// Mirrors JMA's landslide map.json shape. 草津町 (10426) is under an alert
/// (warningCode '3'); 中之条町 (10421) carries the lingering
/// historical/cleared state ('1') that must NOT be shown - treating it as
/// active would paint most of Japan amber on a dry day; 嬬恋村 (10425) is
/// clear ('0').
const _fixture = '''
[
  {"reportDatetime": "2026-07-17T09:00:00+09:00", "targetArea": "100000",
   "areaTypes": [
     {"areas": [{"areaCode": "100010", "warningCode": "1"}]},
     {"areas": [{"areaCode": "1042600", "warningCode": "3"}]},
     {"areas": [
       {"areaCode": "1042600", "warningCode": "3"},
       {"areaCode": "1042100", "warningCode": "1"},
       {"areaCode": "1042500", "warningCode": "0"}
     ]}
   ]}
]''';

http.Client _client({String body = _fixture, int status = 200}) =>
    MockClient((req) async {
      final path = req.url.path;
      if (path.contains('/landslide/map.json')) {
        return http.Response.bytes(utf8.encode(body), status);
      }
      if (path.endsWith('/target.json')) {
        return http.Response('{"target":"202607170900"}', 200);
      }
      if (path.contains('/d/301/')) {
        return http.Response('{"type":"FeatureCollection","features":[]}', 200);
      }
      if (path.contains('pcTukokisei_')) {
        return http.Response('no backup path here', 200);
      }
      return http.Response('not found', 404);
    });

const _kusatsu = LatLng(36.62, 138.60);

void main() {
  test("only warningCode '3' municipalities become alerts", () async {
    final alerts = await LandslideSource(_client()).fetchWhere((_) => true);
    expect(alerts, hasLength(1));
    final a = alerts.single;
    expect(a.id, 'dosha-10426');
    expect(a.roadName, '草津町');
    expect(a.restriction, '土砂災害警戒情報');
    expect(a.isFullClosure, isFalse); // advisory, not a blocked road
    expect(a.sourceUrl.toString(), contains('area_code=1042600'));
    // Placed at the baked municipality-office coordinates, near Kusatsu.
    expect(a.distanceKmFrom(_kusatsu), lessThan(5));
  });

  test('the keep predicate filters by location', () async {
    final src = LandslideSource(_client());
    const dist = Distance();
    final near = await src.fetchWhere(
      (p) => dist.as(LengthUnit.Kilometer, _kusatsu, p) <= 50,
    );
    expect(near, hasLength(1));
    final far = await src.fetchWhere(
      (p) => dist.as(LengthUnit.Kilometer, const LatLng(33, 131), p) <= 50,
    );
    expect(far, isEmpty);
  });

  test('repository appends alerts to merged closures near the rider', () async {
    final repo = ClosureRepository(
      client: _client(),
      seasonal: SeasonalGateSource(gates: const []),
    );
    final (all, errors) = await repo.fetchNear(_kusatsu, 50);
    expect(errors, isEmpty);
    expect(all.map((c) => c.id), contains('dosha-10426'));
  });

  test('a dead landslide feed degrades with its own error label', () async {
    final repo = ClosureRepository(
      client: _client(body: 'oops', status: 500),
      seasonal: SeasonalGateSource(gates: const []),
    );
    final (all, errors) = await repo.fetchNear(_kusatsu, 50);
    expect(all.where((c) => c.id.startsWith('dosha-')), isEmpty);
    expect(errors.join(), contains('土砂災害警戒情報'));
  });
}
