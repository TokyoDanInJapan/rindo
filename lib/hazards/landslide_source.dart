import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../closures/road_closure.dart';
import 'municipalities.g.dart';

/// JMA 土砂災害警戒情報 (landslide alerts, issued jointly with prefectures).
/// One nationwide file keyed by municipality:
///
///   https://www.jma.go.jp/bosai/warning/data/landslide/map.json
///     -> [{ reportDatetime, targetArea, areaTypes: [... {areas:
///        [{areaCode: "1042600", warningCode: "0|1|3"}]}] }]
///
/// warningCode semantics come from JMA's own site code (warning_table.js):
/// ONLY '3' is an alert in effect - '1' is a historical/cleared state that
/// lingers in the file with an old reportDatetime, so treating non-zero as
/// active would paint most of Japan amber on a dry day.
///
/// Alerts are emitted as [RoadClosure]s pinned at the municipality office
/// (baked table, tool/prep_municipalities.dart) so they flow through the
/// same markers/list/translation as everything else. They lead closures:
/// the warning usually comes hours before roads actually shut.
class LandslideSource {
  static const _url =
      'https://www.jma.go.jp/bosai/warning/data/landslide/map.json';
  final http.Client _client;
  LandslideSource(this._client);

  Future<List<RoadClosure>> fetchWhere(bool Function(LatLng) keep) async {
    final r = await _client
        .get(Uri.parse(_url))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw Exception('landslide map ${r.statusCode}');
    }
    final doc = jsonDecode(utf8.decode(r.bodyBytes));
    if (doc is! List) return const [];

    final out = <RoadClosure>[];
    final seen = <String>{};
    for (final office in doc) {
      if (office is! Map) continue;
      final reported = office['reportDatetime'] as String? ?? '';
      final areaTypes = office['areaTypes'];
      if (areaTypes is! List || areaTypes.isEmpty) continue;
      // The last areaType level is class20s (municipalities).
      final areas = (areaTypes.last as Map)['areas'];
      if (areas is! List) continue;
      for (final a in areas) {
        if (a is! Map || a['warningCode'] != '3') continue;
        final class20 = '${a['areaCode']}';
        final code5 = class20.length >= 5 ? class20.substring(0, 5) : class20;
        final m = municipalities[code5];
        // Skip codes the baked table doesn't know (post-merger drift).
        if (m == null || !seen.add(code5)) continue;
        final (name, lat, lon) = m;
        final point = LatLng(lat, lon);
        if (!keep(point)) continue;
        out.add(
          RoadClosure(
            id: 'dosha-$code5',
            point: point,
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
