import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'geojson.dart';
import 'prefectures.dart';
import 'road_closure.dart';

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
  JarticSource(this._client);

  Future<List<RoadClosure>> fetchNear(LatLng center, double radiusKm) {
    const dist = Distance();
    return fetchWhere(
      prefecturesNear(center, radiusKm),
      (p) => dist.as(LengthUnit.Kilometer, center, p) <= radiusKm,
    );
  }

  /// Closures in [prefs] whose point passes [keep]. This is the shared engine
  /// for circle queries, around a point, and corridor queries, along a route.
  Future<List<RoadClosure>> fetchWhere(
    List<Prefecture> prefs,
    bool Function(LatLng) keep,
  ) async {
    if (prefs.isEmpty) return const [];

    final target = await _fetchTarget();
    final tiles = [
      for (final p in prefs)
        if (p.code == '01') ...[
          'R01_1',
          'R01_2',
          'R01_3',
          'R01_4',
          'R01_5',
        ] else
          'R${p.code}',
    ];

    final results = await Future.wait(tiles.map((t) => _fetchTile(target, t)));
    return [
      for (final features in results)
        for (final c in features)
          if (keep(c.point)) c,
    ];
  }

  Future<String> _fetchTarget() async {
    final r = await _client
        .get(Uri.parse('$_base/target.json'))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) throw Exception('JARTIC target ${r.statusCode}');
    final target = (jsonDecode(r.body) as Map)['target'];
    if (target is! String) throw Exception('JARTIC target: unexpected shape');
    return target;
  }

  /// One prefecture tile. A tile that is missing or that fails degrades to 'no
  /// data from this tile' rather than failing the whole search.
  Future<List<RoadClosure>> _fetchTile(String target, String tile) async {
    try {
      final r = await _client
          .get(Uri.parse('$_base/$target/d/301/$tile.json'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return const [];
      // Decode the bytes as UTF-8 explicitly. package:http falls back to
      // Latin-1 when the server omits a charset, which mangles Japanese text.
      final doc = jsonDecode(utf8.decode(r.bodyBytes));
      final features = (doc as Map)['features'];
      if (features is! List) return const [];

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
    } catch (_) {
      return const [];
    }
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

  String? _section(Map props) {
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
