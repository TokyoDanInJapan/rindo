import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'geojson.dart';
import 'prefectures.dart';
import 'road_closure.dart';

/// Full closures on MLIT-managed national highways (直轄国道) from the
/// government 道路情報提供システム, https://www.road-info-prvs.mlit.go.jp/.
/// Narrower coverage than JARTIC but authoritative, with regulation periods
/// and detour text.
///
/// Access is two-step because the data directory is regenerated every few
/// minutes under a random name:
///   1. GET /roadinfo/pc/pcTukokisei_{bureau}_1.html and extract the
///      `backup/{YYYYMMDDHHMMSS}/{random}/` path from a script src.
///   2. GET /roadinfo/backup/{ts}/{rand}/TukoKisei/{bureau}.json (live
///      regulations) and .../TokiTuko/{bureau}.json (winter closures).
/// Records are keyed by '{prefCode}_{prefName}' and carry an icon point
/// [lonStr, latStr] plus an embedded GeoJSON LineString of the section.
class MlitSource {
  static const _base = 'https://www.road-info-prvs.mlit.go.jp/roadinfo';
  static final _backupRe = RegExp(r'backup/\d{14}/[A-Za-z0-9]+/');
  final http.Client _client;
  MlitSource(this._client);

  Future<List<RoadClosure>> fetchNear(LatLng center, double radiusKm) {
    const dist = Distance();
    return fetchWhere(
      prefecturesNear(center, radiusKm),
      (p) => dist.as(LengthUnit.Kilometer, center, p) <= radiusKm,
    );
  }

  /// Closures in the bureaux of [prefs] whose point passes [keep].
  Future<List<RoadClosure>> fetchWhere(
    List<Prefecture> prefs,
    bool Function(LatLng) keep,
  ) async {
    final bureaus = <int>{for (final p in prefs) ...p.mlitBureaus};
    final results = await Future.wait(bureaus.map((b) => _fetchBureau(b)));
    return [
      for (final closures in results)
        for (final c in closures)
          if (keep(c.point)) c,
    ];
  }

  /// One regional development bureau. A failure degrades to 'no data', so one
  /// unreachable bureau cannot kill the whole search.
  Future<List<RoadClosure>> _fetchBureau(int bureau) async {
    try {
      final page = await _client
          .get(Uri.parse('$_base/pc/pcTukokisei_${bureau}_1.html'))
          .timeout(const Duration(seconds: 15));
      if (page.statusCode != 200) return const [];
      final backup = _backupRe.firstMatch(page.body)?.group(0);
      if (backup == null) return const [];

      final categories = await Future.wait([
        _fetchCategory(backup, 'TukoKisei', bureau),
        _fetchCategory(backup, 'TokiTuko', bureau),
      ]);
      return [...categories[0], ...categories[1]];
    } catch (_) {
      return const [];
    }
  }

  Future<List<RoadClosure>> _fetchCategory(
    String backup,
    String category,
    int bureau,
  ) async {
    try {
      final r = await _client
          .get(Uri.parse('$_base/$backup$category/$bureau.json'))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode != 200) return const [];
      // Explicit UTF-8. package:http defaults to Latin-1 without a charset
      // header, which mangles the Japanese field values.
      final doc = jsonDecode(utf8.decode(r.bodyBytes));
      if (doc is! Map) return const [];

      final out = <RoadClosure>[];
      for (final entry in doc.entries) {
        final records = entry.value;
        if (records is! List) continue;
        for (final rec in records) {
          final c = _parseRecord(rec, category, bureau);
          if (c != null) out.add(c);
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  RoadClosure? _parseRecord(dynamic rec, String category, int bureau) {
    if (rec is! Map) return null;

    // TukoKisei mixes all regulation types, so keep only the impassable ones
    // (kisei_naiyo_cd '01' = 通行止). TokiTuko is winter closures, all kept.
    final kiseiName = rec['kisei_meisho'] as String? ?? '';
    if (category == 'TukoKisei' &&
        rec['kisei_naiyo_cd'] != '01' &&
        !kiseiName.contains('通行止')) {
      return null;
    }

    final point = _iconPoint(rec['iconData']);
    if (point == null) return null;

    final start = (rec['kisei_kaishi_chiten'] as String?)?.trim();
    final end = (rec['kisei_syuryo_chiten'] as String?)?.trim();
    final from = (rec['kisei_kaishi_nichiji'] as String?)?.trim();
    final until = (rec['kisei_shuryo_nichiji'] as String?)?.trim();

    return RoadClosure(
      id: 'mlit-${rec['tukokisei_info_id'] ?? point.hashCode}',
      point: point,
      roadName: rec['rosen_name'] as String? ?? '国道',
      section: [
        if (start != null && start.isNotEmpty) start,
        if (end != null && end.isNotEmpty) end,
      ].join('～'),
      restriction: kiseiName.isEmpty
          ? (category == 'TokiTuko' ? '冬期通行止' : '通行止')
          : kiseiName,
      cause: rec['genin_jisho_meisho'] as String?,
      period: [
        if (from != null && from.isNotEmpty) from,
        if (until != null && until.isNotEmpty) until,
      ].join(' ～ '),
      sourceName: '道路情報提供システム（国土交通省）',
      sourceUrl: Uri.parse('$_base/pc/pcTukokisei_${bureau}_1.html'),
      lines: _embeddedLine(rec['geo_json']),
    );
  }

  LatLng? _iconPoint(dynamic iconData) {
    if (iconData is! Map) return null;
    final p = iconData['point'];
    if (p is! List || p.length < 2) return null;
    final lon = double.tryParse('${p[0]}');
    final lat = double.tryParse('${p[1]}');
    if (lon == null || lat == null) return null;
    return LatLng(lat, lon);
  }

  /// `geo_json` is a JSON *string* holding one Feature with a LineString.
  List<List<LatLng>> _embeddedLine(dynamic geoJson) {
    if (geoJson is! String || geoJson.isEmpty) return const [];
    try {
      final geometry = (jsonDecode(geoJson) as Map)['geometry'] as Map;
      final lines = geometryLines(geometry);
      // Some records omit the geometry type, so treat bare coordinates as a
      // LineString rather than dropping them.
      return lines.isNotEmpty ? lines : [latLngLine(geometry['coordinates'])];
    } catch (_) {
      return const [];
    }
  }
}
