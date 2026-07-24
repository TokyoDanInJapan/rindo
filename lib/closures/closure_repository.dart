import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:latlong2/latlong.dart';

import '../hazards/landslide_source.dart';
import '../route/gpx_route.dart';
import 'jartic_source.dart';
import 'mlit_source.dart';
import 'prefectures.dart';
import 'road_closure.dart';
import 'seasonal_gates.dart';

/// Combines the closure feeds: the curated seasonal-gate dataset (the only
/// source that knows about *upcoming* winter closures), MLIT's 道路情報提供
/// システム (authoritative, national highways only), JARTIC's live map data
/// (everything else, notably prefectural roads), plus JMA 土砂災害警戒情報
/// landslide alerts (municipality-level, they lead the actual closures).
/// The same closure can appear in several feeds, so near-duplicates are
/// collapsed with precedence seasonal > MLIT > JARTIC (richer metadata
/// wins); landslide alerts never collide (no route numbers) and are simply
/// appended.
class ClosureRepository {
  final JarticSource _jartic;
  final MlitSource _mlit;
  final SeasonalGateSource _seasonal;
  final LandslideSource _landslide;
  final DateTime Function() _now;

  ClosureRepository({
    http.Client? client,
    SeasonalGateSource? seasonal,
    DateTime Function()? now,
  }) : this._(client ?? http.Client(), seasonal, now);

  ClosureRepository._(
    http.Client client,
    SeasonalGateSource? seasonal,
    DateTime Function()? now,
  ) : _jartic = JarticSource(client),
      _mlit = MlitSource(client), // one shared client, one pool
      _seasonal = seasonal ?? SeasonalGateSource(now: now),
      _landslide = LandslideSource(client),
      _now = now ?? DateTime.now;

  String get attribution => 'Closures: JARTIC · 国土交通省';
  Uri get attributionUrl => Uri.parse('https://www.jartic.or.jp/map/');

  /// Merged closures plus one message per source that failed. One dead
  /// source must not blank the list - the bundled seasonal gates work with
  /// no network at all, and a JARTIC outage shouldn't hide MLIT data.
  Future<(List<RoadClosure>, List<String>)> fetchNear(
    LatLng center,
    double radiusKm,
  ) {
    const dist = Distance();
    return _fetchMerged(
      seasonal: _seasonal.fetchNear(center, radiusKm),
      mlit: _mlit.fetchNear(center, radiusKm),
      jartic: _jartic.fetchNear(center, radiusKm),
      landslide: _landslide.fetchWhere(
        (p) => dist.as(LengthUnit.Kilometer, center, p) <= radiusKm,
      ),
    );
  }

  /// Closures within [radiusKm] of any point on [route] (a GPX track, say).
  Future<(List<RoadClosure>, List<String>)> fetchAlong(
    List<LatLng> route,
    double radiusKm,
  ) {
    // ~2 km spacing keeps the corridor test cheap; the edge wobble that
    // introduces is noise against a 10 km scouting radius.
    final thinned = thinRoute(route, 2);
    final prefs = prefecturesAlong(thinned, radiusKm);
    bool keep(LatLng p) => nearRoute(thinned, p, radiusKm);
    return _fetchMerged(
      seasonal: _seasonal.fetchWhere((c) => keep(c.point)),
      mlit: _mlit.fetchWhere(prefs, keep),
      jartic: _jartic.fetchWhere(prefs, keep),
      landslide: _landslide.fetchWhere(keep),
    );
  }

  Future<(List<RoadClosure>, List<String>)> _fetchMerged({
    required Future<List<RoadClosure>> seasonal,
    required Future<List<RoadClosure>> mlit,
    required Future<List<RoadClosure>> jartic,
    required Future<List<RoadClosure>> landslide,
  }) async {
    final results = await Future.wait([
      _guard('冬期閉鎖', seasonal),
      _guard('MLIT', mlit),
      _guard('JARTIC', jartic),
      _guard('土砂災害警戒情報', landslide),
    ]);
    final errors = [for (final (_, error) in results) ?error];
    final merged = _merge(results[0].$1, results[1].$1, results[2].$1);
    return ([...merged, ...results[3].$1], errors);
  }

  List<RoadClosure> _merge(
    List<RoadClosure> seasonal,
    List<RoadClosure> mlit,
    List<RoadClosure> jartic,
  ) {
    // A live record matching a curated gate that is closed *now* is the gate
    // itself - the curated entry wins (it carries the reopening date). While
    // a gate is merely scheduled, a live closure on the same road is a
    // separate event (typhoon damage in summer, say) and must survive.
    final now = _now();
    final activeGates = [
      for (final s in seasonal)
        if (s.statusAt(now) == ClosureStatus.active) s,
    ];

    final out = [...seasonal];
    final keptMlit = <RoadClosure>[];
    for (final m in mlit) {
      if (!debugIsDuplicate(m, activeGates)) {
        out.add(m);
        keptMlit.add(m);
      }
    }
    for (final j in jartic) {
      if (!debugIsDuplicate(j, [...activeGates, ...keptMlit])) out.add(j);
    }
    return out;
  }

  Future<(List<RoadClosure>, String?)> _guard(
    String label,
    Future<List<RoadClosure>> fetch,
  ) async {
    try {
      return (await fetch, null);
    } catch (e) {
      return (const <RoadClosure>[], '$label: $e');
    }
  }

  @visibleForTesting
  bool debugIsDuplicate(RoadClosure candidate, List<RoadClosure> kept) {
    const dist = Distance();
    return kept.any(
      (m) =>
          _sameRoad(m.roadName, candidate.roadName) &&
          dist.as(LengthUnit.Kilometer, m.point, candidate.point) < 5,
    );
  }

  /// Same route class and number? Digits are normalised (JARTIC serves
  /// full-width, "国道１６号" vs MLIT's "国道16号"). 都道/道道/府道/県道 count
  /// as one class: a cross-border prefectural road keeps its number on both
  /// sides of the border, and the 5 km proximity test already rules out
  /// same-numbered roads in unrelated prefectures.
  bool _sameRoad(String a, String b) {
    final ka = _routeKey(a), kb = _routeKey(b);
    return ka != null && ka == kb;
  }

  static final _routeRe = RegExp(r'(国道|都道|道道|府道|県道)(\d+)号');

  (String, String)? _routeKey(String roadName) {
    final normalized = roadName.replaceAllMapped(
      RegExp(r'[０-９]'),
      (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0xFEE0),
    );
    final m = _routeRe.firstMatch(normalized);
    if (m == null) return null;
    final cls = m.group(1) == '国道' ? '国道' : '県道';
    return (cls, m.group(2)!);
  }
}
