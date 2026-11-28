import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../closures/feed_result.dart';
import '../closures/road_closure.dart';
import '../closures/search_area.dart';
import '../net/feed_exception.dart';
import '../net/feed_fetch.dart';
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

  // The last map read, with its validators. The file changes only when an
  // alert is issued or cleared, which can be months apart. Each refresh
  // therefore asks JMA whether it changed, and a 304 costs no download and
  // no parse.
  Validated<List<RoadClosure>>? _map;

  LandslideSource(this._client, {DateTime Function()? now})
    : _lastGood = LastGood(now: now);

  /// Alerts in effect inside [area]. The map is one nationwide file, so a
  /// failed fetch falls back to the last one read, whatever area it served.
  Future<FeedResult> fetch(SearchArea area) async {
    final (all, _, error) = await _lastGood.fetchOr(null, _fetchAll);
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

  static FeedException _error(String message) =>
      FeedException('JMA landslide', message);

  /// Every alert in effect nationwide. Only plain bytes and the static parser
  /// cross the isolate boundary; the client and cache stay on the UI isolate.
  Future<List<RoadClosure>> _fetchAll() async {
    final map = await fetchFeedIfChanged(
      _client,
      Uri.parse(_url),
      previous: _map,
      deadline: const Duration(seconds: 15),
      resource: 'map',
      error: _error,
      parse: (bytes) => parseFeedBytes(bytes, _parseMap),
    );
    _map = map;
    return map.value;
  }

  static List<RoadClosure> _parseMap(Uint8List bytes) {
    final doc = decodeFeedJson<List<dynamic>>(
      bytes,
      resource: 'map',
      error: _error,
    );
    final offices = parseFeedRecords(
      doc,
      _parseOffice,
      resource: 'map',
      error: _error,
    );
    final seen = <String>{};
    return [
      for (final office in offices)
        for (final alert in office)
          if (seen.add(alert.id)) alert,
    ];
  }

  static List<RoadClosure> _parseOffice(dynamic office) {
    if (office is! Map) throw const FormatException('office is not an object');
    final reported = office['reportDatetime'] as String? ?? '';
    final areaTypes = office['areaTypes'];
    if (areaTypes is! List || areaTypes.isEmpty) {
      throw const FormatException('missing areaTypes');
    }
    // The last areaType level is the class20s, the municipalities.
    final last = areaTypes.last;
    final areas = last is Map ? last['areas'] : null;
    if (areas is! List) throw const FormatException('missing areas');
    return parseFeedRecords(
      areas,
      (area) => _parseArea(area, reported),
      resource: 'office areas',
      error: _error,
    );
  }

  static RoadClosure? _parseArea(dynamic area, String reported) {
    if (area is! Map ||
        area['warningCode'] is! String ||
        area['areaCode'] is! String) {
      throw const FormatException('missing warning or area code');
    }
    if (area['warningCode'] != '3') return null;
    final class20 = area['areaCode'] as String;
    final code5 = class20.length >= 5 ? class20.substring(0, 5) : class20;
    final municipality = municipalities[code5];
    // Skip codes the baked table does not know, from post-merger drift.
    if (municipality == null) return null;
    final (name, lat, lon) = municipality;
    return RoadClosure(
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
    );
  }
}
