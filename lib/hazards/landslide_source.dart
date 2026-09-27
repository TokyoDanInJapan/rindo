import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../closures/feed_result.dart';
import '../closures/road_closure.dart';
import '../closures/search_area.dart';
import '../net/feed_exception.dart';
import 'municipalities.g.dart';

/// JMA 土砂災害警戒情報 (landslide alerts, issued jointly with prefectures).
/// One nationwide file keyed by municipality:
///
///   https://www.jma.go.jp/bosai/warning/data/landslide/map.json
///     -> [{ reportDatetime, targetArea, areaTypes: [... {areas:
///        [{areaCode: "1042600", warningCode: "0|1|3"}]}] }]
///
/// The warningCode semantics come from JMA's own site code
/// (warning_table.js). ONLY '3' is an alert in effect. A '1' is a historical,
/// cleared state that lingers in the file with an old reportDatetime, so
/// treating any non-zero value as active would paint most of Japan amber on a
/// dry day.
///
/// Alerts are emitted as [RoadClosure]s pinned at the municipality office,
/// from the baked table in tool/prep_municipalities.dart, so they flow through
/// the same markers, list and translation as everything else. They lead the
/// closures, because the warning usually comes hours before roads actually
/// shut.
class LandslideSource {
  static const _url =
      'https://www.jma.go.jp/bosai/warning/data/landslide/map.json';
  final http.Client _client;
  final LastGood<void> _lastGood;

  LandslideSource(this._client, {DateTime Function()? now})
    : _lastGood = LastGood(now: now);

  /// Alerts in effect inside [area]. The map is one nationwide file, so a
  /// failed fetch falls back to the last one read, whatever area it served.
  Future<FeedResult> fetch(SearchArea area) async {
    List<RoadClosure>? all;
    Object? error;
    try {
      all = await _fetchAll();
      _lastGood.put(null, all);
    } catch (e) {
      error = e;
      all = _lastGood.get(null);
    }
    return FeedResult(
      [
        for (final c in all ?? const <RoadClosure>[])
          if (area.contains(c.point)) c,
      ],
      [
        if (error != null)
          all == null ? '$error' : '$error, showing the last data received',
      ],
    );
  }

  /// Every alert in effect nationwide.
  Future<List<RoadClosure>> _fetchAll() async {
    final r = await _client
        .get(Uri.parse(_url))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw FeedException('JMA landslide', 'map ${r.statusCode}');
    }
    final doc = jsonDecode(utf8.decode(r.bodyBytes));
    if (doc is! List) {
      throw FeedException('JMA landslide', 'map: unexpected shape');
    }

    final out = <RoadClosure>[];
    final seen = <String>{};
    for (final office in doc) {
      if (office is! Map) continue;
      final reported = office['reportDatetime'] as String? ?? '';
      final areaTypes = office['areaTypes'];
      if (areaTypes is! List || areaTypes.isEmpty) continue;
      // The last areaType level is the class20s, the municipalities.
      final last = areaTypes.last;
      final areas = last is Map ? last['areas'] : null;
      if (areas is! List) continue;
      for (final a in areas) {
        if (a is! Map || a['warningCode'] != '3') continue;
        final class20 = '${a['areaCode']}';
        final code5 = class20.length >= 5 ? class20.substring(0, 5) : class20;
        final m = municipalities[code5];
        // Skip codes the baked table does not know, from post-merger drift.
        if (m == null || !seen.add(code5)) continue;
        final (name, lat, lon) = m;
        out.add(
          RoadClosure(
            id: 'dosha-$code5',
            point: LatLng(lat, lon),
            roadName: name,
            restriction: '土砂災害警戒情報',
            cause: '大雨による土砂災害のおそれ（発表 $reported）',
            sourceName: '気象庁 土砂災害警戒情報',
            sourceUrl: Uri.parse(
              'https://www.jma.go.jp/bosai/warning/'
              '#area_type=class20s&area_code=$class20',
            ),
          ),
        );
      }
    }
    return out;
  }
}
