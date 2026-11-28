import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';
import 'package:latlong2/latlong.dart';

import '../hazards/landslide_source.dart';
import 'feed_result.dart';
import 'jartic_source.dart';
import 'mlit_source.dart';
import 'road_closure.dart';
import 'search_area.dart';
import 'seasonal_gates.dart';

/// Combines the closure feeds: the curated seasonal-gate dataset (the only
/// source that knows about *upcoming* winter closures), MLIT's 道路情報提供
/// システム (authoritative, national highways only), JARTIC's live map data
/// (everything else, notably prefectural roads), plus JMA 土砂災害警戒情報
/// landslide alerts (municipality-level, they lead the actual closures).
/// The same closure can appear in several feeds, so near-duplicates are
/// collapsed with the precedence seasonal > MLIT > JARTIC, where the richer
/// metadata wins. Landslide alerts never collide, because they carry no route
/// numbers, so they are simply appended.
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

  // One shared client, one connection pool.
  ClosureRepository._(
    http.Client client,
    SeasonalGateSource? seasonal,
    DateTime Function()? now,
  ) : _jartic = JarticSource(client, now: now),
      _mlit = MlitSource(client, now: now),
      _seasonal = seasonal ?? SeasonalGateSource(now: now),
      _landslide = LandslideSource(client, now: now),
      _now = now ?? DateTime.now;

  String get attribution => 'Closures: JARTIC · 国土交通省';
  Uri get attributionUrl => Uri.parse('https://www.jartic.or.jp/map/');

  /// Merged closures inside [area], plus one message per source problem. One
  /// dead source must not blank the list. The bundled seasonal gates work
  /// with no network at all, and a JARTIC outage should not hide MLIT data.
  /// The live sources fall back to the last data they fetched for any part
  /// that fails, and still report it.
  Future<(List<RoadClosure>, List<String>)> fetch(SearchArea area) async {
    final results = await Future.wait([
      _guard('冬期閉鎖', _seasonal.fetch(area)),
      _guard('MLIT', _mlit.fetch(area)),
      _guard('JARTIC', _jartic.fetch(area)),
      _guard('土砂災害警戒情報', _landslide.fetch(area)),
    ]);
    final errors = [for (final (_, problems) in results) ...problems];
    final merged = _merge(results[0].$1, results[1].$1, results[2].$1);
    return ([...merged, ...results[3].$1], errors);
  }

  /// Closures within [radiusKm] of [center].
  Future<(List<RoadClosure>, List<String>)> fetchNear(
    LatLng center,
    double radiusKm,
  ) => fetch(CircleArea(center, radiusKm));

  /// Closures within [radiusKm] of any point on [route] (a GPX track, say).
  Future<(List<RoadClosure>, List<String>)> fetchAlong(
    List<LatLng> route,
    double radiusKm,
  ) => fetch(CorridorArea(route, radiusKm));

  List<RoadClosure> _merge(
    List<RoadClosure> seasonal,
    List<RoadClosure> mlit,
    List<RoadClosure> jartic,
  ) {
    // A live record matching a curated gate that is closed *now* is the gate
    // itself, so the curated entry wins, because it carries the reopening
    // date. While a gate is merely scheduled, a live closure on the same road
    // is a separate event, typhoon damage in summer for example, and must
    // survive.
    final now = _now();
    final kept = [
      for (final s in seasonal)
        if (s.statusAt(now) == ClosureStatus.active) (s, _routeKey(s.roadName)),
    ];

    final out = [...seasonal];
    for (final m in mlit) {
      final key = _routeKey(m.roadName);
      if (!_isDuplicate(m, key, kept)) {
        out.add(m);
        kept.add((m, key));
      }
    }
    for (final j in jartic) {
      if (!_isDuplicate(j, _routeKey(j.roadName), kept)) out.add(j);
    }
    return out;
  }

  /// A source's closures and its problems, each labelled with the source. A
  /// source that throws outright still yields an empty list and one line.
  Future<(List<RoadClosure>, List<String>)> _guard(
    String label,
    Future<FeedResult> fetch,
  ) async {
    try {
      final r = await fetch;
      return (r.closures, [for (final p in r.problems) '$label: $p']);
    } catch (e) {
      return (const <RoadClosure>[], ['$label: $e']);
    }
  }

  @visibleForTesting
  bool debugIsDuplicate(RoadClosure candidate, List<RoadClosure> kept) =>
      _isDuplicate(candidate, _routeKey(candidate.roadName), [
        for (final closure in kept) (closure, _routeKey(closure.roadName)),
      ]);

  bool _isDuplicate(
    RoadClosure candidate,
    (String, String)? key,
    List<(RoadClosure, (String, String)?)> kept,
  ) {
    if (key == null) return false;
    const dist = Distance(calculator: Haversine());
    return kept.any(
      (entry) =>
          key == entry.$2 &&
          dist.as(LengthUnit.Kilometer, entry.$1.point, candidate.point) < 5,
    );
  }

  // Normalise each closure's route key once per merge, before the pairwise
  // proximity checks. National and prefectural roads remain separate classes;
  // 都道, 道道, 府道 and 県道 share a class across prefectural borders.
  static final _routeRe = RegExp(r'(国道|都道|道道|府道|県道)(\d+)号');
  static final _fullWidthDigit = RegExp(r'[０-９]');

  (String, String)? _routeKey(String roadName) {
    final normalized = roadName.replaceAllMapped(
      _fullWidthDigit,
      (m) => String.fromCharCode(m.group(0)!.codeUnitAt(0) - 0xFEE0),
    );
    final m = _routeRe.firstMatch(normalized);
    if (m == null) return null;
    final cls = m.group(1) == '国道' ? '国道' : '県道';
    return (cls, m.group(2)!);
  }
}
