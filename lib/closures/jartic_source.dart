import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../net/feed_exception.dart';
import 'feed_result.dart';
import 'geojson.dart';
import 'road_closure.dart';
import 'search_area.dart';

/// Live full-closure (通行止) data from JARTIC's 道路交通情報Now!! map: the
/// undocumented GeoJSON endpoints behind https://www.jartic.or.jp/map/.
/// This is the only national source that covers prefectural roads, which are
/// the roads that actually matter on a bike. It is not an official API and can
/// change without notice. Note that JARTIC's terms limit the site to private
/// use. That is fine for a personal tool, but ask JARTIC before you distribute
/// it publicly.
///
///   generation: GET /d/traffic_info/r1/target.json -> {"target":"YYYYMMDDHHmm"}
///   closures:   GET /d/traffic_info/r1/{target}/d/301/{tile}.json
///     tile = R{prefCode} for general roads (Hokkaido splits into R01_1..R01_5)
///
/// Feature properties: rd = regulation text, cs = regulation code ('01' =
/// full closure), c = cause, r = road name, i = section or place, d =
/// direction, p = representative points [[lon,lat]]. The geometry is a
/// (Multi)LineString in JGD2000 lon/lat, treated here as WGS84, because the
/// difference is centimetres.
class JarticSource {
  static const _base = 'https://www.jartic.or.jp/d/traffic_info/r1';
  final http.Client _client;
  final LastGood<String> _lastGood;

  JarticSource(this._client, {DateTime Function()? now})
    : _lastGood = LastGood(now: now);

  /// Closures inside [area]. A prefecture tile that fails falls back to the
  /// last one fetched, and the failure is listed in the result either way.
  /// One tile failing never costs the others.
  Future<FeedResult> fetch(SearchArea area) async {
    final tiles = {
      for (final p in area.prefectures)
        if (p.code == '01') ...[
          'R01_1',
          'R01_2',
          'R01_3',
          'R01_4',
          'R01_5',
        ] else
          'R${p.code}',
    };
    if (tiles.isEmpty) return const FeedResult([]);

    // Without the generation index there is no tile to fetch, but the last
    // good tiles can still answer.
    String? target;
    Object? targetError;
    try {
      target = await _fetchTarget();
    } catch (e) {
      targetError = e;
    }

    final results = await Future.wait(tiles.map((t) => _tileOrLast(target, t)));
    var failed = 0;
    var fellBack = false;
    final out = <RoadClosure>[];
    for (final (closures, fresh) in results) {
      if (!fresh) {
        failed++;
        fellBack |= closures != null;
      }
      for (final c in closures ?? const <RoadClosure>[]) {
        if (area.contains(c.point)) out.add(c);
      }
    }
    return FeedResult(out, [
      if (failed > 0)
        partsProblem(
          failed: failed,
          total: tiles.length,
          unit: 'prefecture feeds',
          fellBack: fellBack,
          cause: targetError,
        ),
    ]);
  }

  /// One tile, freshly fetched, or else the last good copy. The flag says
  /// which. Null closures means it failed with nothing to fall back on.
  Future<(List<RoadClosure>?, bool)> _tileOrLast(
    String? target,
    String tile,
  ) async {
    if (target != null) {
      try {
        final fresh = await _fetchTile(target, tile);
        _lastGood.put(tile, fresh);
        return (fresh, true);
      } catch (_) {
        // Counted by the caller, and reported as a missing tile.
      }
    }
    return (_lastGood.get(tile), false);
  }

  Future<String> _fetchTarget() async {
    final r = await _client
        .get(Uri.parse('$_base/target.json'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw FeedException('JARTIC', 'target ${r.statusCode}');
    }
    final doc = jsonDecode(r.body);
    final target = doc is Map ? doc['target'] : null;
    if (target is! String) {
      throw FeedException('JARTIC', 'target: unexpected shape');
    }
    return target;
  }

  /// One prefecture tile. It throws when the tile cannot be read, so the
  /// caller can fall back. A 404 is a tile JARTIC does not publish, which is
  /// an empty tile rather than a failure.
  Future<List<RoadClosure>> _fetchTile(String target, String tile) async {
    final r = await _client
        .get(Uri.parse('$_base/$target/d/301/$tile.json'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode == 404) return const [];
    if (r.statusCode != 200) {
      throw FeedException('JARTIC', '$tile ${r.statusCode}');
    }
    // Decode the bytes as UTF-8 explicitly. package:http falls back to
    // Latin-1 when the server omits a charset, which mangles Japanese text.
    final doc = jsonDecode(utf8.decode(r.bodyBytes));
    final features = doc is Map ? doc['features'] : null;
    if (features is! List) {
      throw FeedException('JARTIC', '$tile: unexpected shape');
    }

    final out = <RoadClosure>[];
    for (final f in features) {
      try {
        final c = _parseFeature(f, tile);
        if (c != null) out.add(c);
      } catch (_) {
        // One malformed feature must not discard the rest of the tile.
      }
    }
    return out;
  }

  RoadClosure? _parseFeature(dynamic f, String tile) {
    if (f is! Map) return null;
    final props = f['properties'];
    if (props is! Map) return null;

    // Only impassable regulations: cs '01' is JARTIC's full-closure code.
    final rd = props['rd'] as String? ?? '';
    if (props['cs'] != '01' && !rd.contains('通行止')) return null;

    final lines = geometryLines(f['geometry']);
    final point = _representativePoint(props['p'], lines);
    if (point == null) return null;

    final pref = tile.substring(1, 3); // "R13" / "R01_2" -> "13" / "01"
    return RoadClosure(
      id: 'jartic-${props['rn'] ?? point.hashCode}',
      point: point,
      roadName: (props['r'] as String?)?.trim().isNotEmpty == true
          ? (props['r'] as String).trim()
          : '道路名不明',
      section: _section(props),
      restriction: rd.isEmpty ? '通行止' : rd,
      cause: props['c'] as String?,
      sourceName: 'JARTIC 道路交通情報',
      sourceUrl: Uri.parse(
        'https://www.jartic.or.jp/map/'
        '?area=R$pref&lat=${point.latitude}&lon=${point.longitude}&z=13',
      ),
      lines: lines,
    );
  }

  String? _section(Map<dynamic, dynamic> props) {
    final i = (props['i'] as String?)?.trim();
    final d = (props['d'] as String?)?.trim();
    if (i == null || i.isEmpty) return null;
    return d == null || d.isEmpty ? i : '$i（$d）';
  }

  /// `p` holds one or more representative points as GeoJSON positions. When
  /// `p` is absent, fall back to the start of the regulated segment.
  LatLng? _representativePoint(dynamic p, List<List<LatLng>> lines) {
    final pts = latLngLine(p);
    if (pts.isNotEmpty) return pts.first;
    if (lines.isNotEmpty && lines.first.isNotEmpty) return lines.first.first;
    return null;
  }
}
