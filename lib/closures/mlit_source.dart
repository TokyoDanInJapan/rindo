import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../net/feed_exception.dart';
import 'feed_result.dart';
import 'geojson.dart';
import 'road_closure.dart';
import 'search_area.dart';

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
  static const _categories = ['TukoKisei', 'TokiTuko'];
  final http.Client _client;
  final LastGood<(int, String)> _lastGood;

  MlitSource(this._client, {DateTime Function()? now})
    : _lastGood = LastGood(now: now);

  /// Closures inside [area], from the bureaux that cover its prefectures. A
  /// bureau file that fails falls back to the last one fetched, and the
  /// failure is listed in the result either way.
  Future<FeedResult> fetch(SearchArea area) async {
    final bureaus = <int>{for (final p in area.prefectures) ...p.mlitBureaus};
    if (bureaus.isEmpty) return const FeedResult([]);
    final results = await Future.wait(bureaus.map(_bureauOrLast));

    var failed = 0;
    var fellBack = false;
    final out = <RoadClosure>[];
    for (final parts in results) {
      for (final (closures, fresh) in parts) {
        if (!fresh) {
          failed++;
          fellBack |= closures != null;
        }
        for (final c in closures ?? const <RoadClosure>[]) {
          if (area.contains(c.point)) out.add(c);
        }
      }
    }
    return FeedResult(out, [
      if (failed > 0)
        partsProblem(
          failed: failed,
          total: bureaus.length * _categories.length,
          unit: 'bureau files',
          fellBack: fellBack,
        ),
    ]);
  }

  /// Both category files of one regional development bureau, each freshly
  /// fetched or else its last good copy. The flag says which.
  Future<List<(List<RoadClosure>?, bool)>> _bureauOrLast(int bureau) async {
    String? backup;
    try {
      backup = await _fetchBackupPath(bureau);
    } catch (_) {
      // Both categories fall back below.
    }
    return Future.wait([
      for (final category in _categories)
        () async {
          final key = (bureau, category);
          if (backup != null) {
            try {
              final fresh = await _fetchCategory(backup, category, bureau);
              _lastGood.put(key, fresh);
              return (fresh, true);
            } catch (_) {
              // Counted by the caller, and reported as a missing file.
            }
          }
          return (_lastGood.get(key), false);
        }(),
    ]);
  }

  /// The regenerated data directory, scraped from the bureau's page. It
  /// throws when the page is unreachable or no longer names one.
  Future<String> _fetchBackupPath(int bureau) async {
    final page = await _client
        .get(Uri.parse('$_base/pc/pcTukokisei_${bureau}_1.html'))
        .timeout(const Duration(seconds: 15));
    if (page.statusCode != 200) {
      throw FeedException('MLIT', 'bureau $bureau page ${page.statusCode}');
    }
    final backup = _backupRe.firstMatch(page.body)?.group(0);
    if (backup == null) {
      throw FeedException('MLIT', 'bureau $bureau page: no data path');
    }
    return backup;
  }

  /// One category file. It throws when the file cannot be read, so the
  /// caller can fall back. A 404 is a category with nothing published.
  Future<List<RoadClosure>> _fetchCategory(
    String backup,
    String category,
    int bureau,
  ) async {
    final r = await _client
        .get(Uri.parse('$_base/$backup$category/$bureau.json'))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode == 404) return const [];
    if (r.statusCode != 200) {
      throw FeedException('MLIT', '$category/$bureau ${r.statusCode}');
    }
    // Explicit UTF-8. package:http defaults to Latin-1 without a charset
    // header, which mangles the Japanese field values.
    final doc = jsonDecode(utf8.decode(r.bodyBytes));
    if (doc is! Map) {
      throw FeedException('MLIT', '$category/$bureau: unexpected shape');
    }

    final out = <RoadClosure>[];
    for (final records in doc.values) {
      if (records is! List) continue;
      for (final rec in records) {
        final c = _parseRecord(rec, category, bureau);
        if (c != null) out.add(c);
      }
    }
    return out;
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
      section: _joinOrNull([start, end], '～'),
      restriction: kiseiName.isEmpty
          ? (category == 'TokiTuko' ? '冬期通行止' : '通行止')
          : kiseiName,
      cause: rec['genin_jisho_meisho'] as String?,
      period: _joinOrNull([from, until], ' ～ '),
      sourceName: '道路情報提供システム（国土交通省）',
      sourceUrl: Uri.parse('$_base/pc/pcTukokisei_${bureau}_1.html'),
      lines: _embeddedLine(rec['geo_json']),
    );
  }

  /// The non-empty [parts] joined, or null when there are none. An empty
  /// string would show as a blank 'Section:' line and a stray separator.
  static String? _joinOrNull(List<String?> parts, String separator) {
    final present = [
      for (final p in parts)
        if (p != null && p.isNotEmpty) p,
    ];
    return present.isEmpty ? null : present.join(separator);
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
