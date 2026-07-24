import 'package:latlong2/latlong.dart';
import 'package:meta/meta.dart';

import 'road_closure.dart';
import 'seasonal_gate_lines.g.dart';

/// A curated seasonal (winter) closure gate. The live feeds only report what
/// is closed *right now*; this dataset answers the planning question - "will
/// that pass be open in October?" - for the annual gates the prefectures
/// publish. Dates are nominal: the real gate dates shift with snowfall each
/// season, so the live feeds stay the ground truth for "closed today".
class SeasonalGate {
  final String id;
  final String roadName; // e.g. '国道292号（志賀草津道路）'
  final String section; // closed section / gate names
  final double lat, lon; // the pass or gate, not exact gate posts
  final int closesMonth, closesDay; // nominal annual gate closing
  final int opensMonth, opensDay; // nominal annual gate opening
  final String? note; // rider-relevant extra, e.g. マイカー規制
  final String sourceUrl; // authoritative seasonal info page

  const SeasonalGate({
    required this.id,
    required this.roadName,
    required this.section,
    required this.lat,
    required this.lon,
    required this.closesMonth,
    required this.closesDay,
    required this.opensMonth,
    required this.opensDay,
    required this.sourceUrl,
    this.note,
  });
}

/// Curated from the prefectures' 2025–26 winter-closure notices (verified
/// 2026-07). Update once a year when the annual notices appear; coordinates
/// mark the pass itself.
const seasonalGates = <SeasonalGate>[
  SeasonalGate(
    id: 'r292-shibu',
    roadName: '国道292号（志賀草津道路）',
    section: '天狗山ゲート～渋峠（群馬/長野県境）',
    lat: 36.6663,
    lon: 138.5345,
    closesMonth: 11,
    closesDay: 12,
    opensMonth: 4,
    opensDay: 22,
    note: '国道最高地点 2,172 m。噴火警戒レベルによる別途規制あり',
    sourceUrl: 'https://www.shigakogen.gr.jp/road_condition.html',
  ),
  SeasonalGate(
    id: 'r299-mugikusa',
    roadName: '国道299号（メルヘン街道）',
    section: '茅野市北山～麦草峠～小海町',
    lat: 36.0592,
    lon: 138.3472,
    closesMonth: 11,
    closesDay: 20,
    opensMonth: 4,
    opensDay: 16,
    note: '麦草峠 2,127 m',
    sourceUrl:
        'https://www.city.chino.lg.jp/soshiki/kensetsu-suishin/2001.html',
  ),
  SeasonalGate(
    id: 'r120-konsei',
    roadName: '国道120号（金精道路）',
    section: '片品村丸沼～金精トンネル～日光湯元',
    lat: 36.8189,
    lon: 139.3950,
    closesMonth: 12,
    closesDay: 25,
    opensMonth: 4,
    opensDay: 24,
    note: '金精峠 2,024 m（トンネル 1,840 m）',
    sourceUrl: 'https://www.pref.tochigi.lg.jp/h05/',
  ),
  SeasonalGate(
    id: 'gifu5-norikura-skyline',
    roadName: '岐阜県道5号（乗鞍スカイライン）',
    section: '平湯峠～畳平',
    lat: 36.1230,
    lon: 137.5530,
    closesMonth: 11,
    closesDay: 1,
    opensMonth: 5,
    opensDay: 15,
    note: '開通期間中もマイカー規制（自転車・バスは通行可）',
    sourceUrl: 'https://norikuradake.jp/',
  ),
  SeasonalGate(
    id: 'nagano84-norikura-echoline',
    roadName: '長野県道84号（乗鞍エコーライン）',
    section: '三本滝～畳平（県境）',
    lat: 36.1200,
    lon: 137.5580,
    closesMonth: 11,
    closesDay: 1,
    opensMonth: 7,
    opensDay: 1,
    note: '開通期間中もマイカー規制（自転車・バスは通行可）',
    sourceUrl:
        'https://www.pref.nagano.lg.jp/shizenhogo/infra/doro/joho/norikuradake.html',
  ),
];

/// Bundled-data source with the same `fetchNear` shape as the live sources,
/// so the repository treats all three alike. Never touches the network.
class SeasonalGateSource {
  final List<SeasonalGate> _gates;
  final DateTime Function() _now;

  SeasonalGateSource({List<SeasonalGate>? gates, DateTime Function()? now})
    : _gates = gates ?? seasonalGates,
      _now = now ?? DateTime.now;

  Future<List<RoadClosure>> fetchNear(LatLng center, double radiusKm) =>
      fetchWhere((c) => c.distanceKmFrom(center) <= radiusKm);

  /// Gates whose materialised closure passes [keep].
  Future<List<RoadClosure>> fetchWhere(bool Function(RoadClosure) keep) async {
    final now = _now();
    return [
      for (final g in _gates)
        if (_toClosure(g, now) case final c when keep(c)) c,
    ];
  }

  /// The gate's current-or-next closure window relative to [now]: the window
  /// containing [now], else the next to start. Windows normally span new
  /// year (close in Nov, open in Apr), so try starting years around [now].
  @visibleForTesting
  static (DateTime, DateTime) windowAt(SeasonalGate g, DateTime now) {
    for (var y = now.year - 1; y <= now.year + 1; y++) {
      final from = DateTime(y, g.closesMonth, g.closesDay);
      var until = DateTime(y, g.opensMonth, g.opensDay);
      if (!until.isAfter(from)) {
        until = DateTime(y + 1, g.opensMonth, g.opensDay);
      }
      if (now.isBefore(until)) return (from, until);
    }
    throw StateError('no window found for ${g.id}'); // unreachable
  }

  RoadClosure _toClosure(SeasonalGate g, DateTime now) {
    final (from, until) = windowAt(g, now);
    return RoadClosure(
      id: 'seasonal-${g.id}',
      point: LatLng(g.lat, g.lon),
      roadName: g.roadName,
      section: g.section,
      restriction: '冬期通行止',
      cause: g.note ?? '積雪',
      period:
          '例年 ${g.closesMonth}/${g.closesDay} ～ '
          '${g.opensMonth}/${g.opensDay}（積雪状況により変動）',
      sourceName: '冬期閉鎖情報（手動収集）',
      sourceUrl: Uri.parse(g.sourceUrl),
      validFrom: from,
      validUntil: until,
      isSeasonal: true,
      // Road geometry baked from OSM by tool/fetch_gate_lines.dart, so the
      // whole closed section highlights, not just a pin at the pass.
      lines: seasonalGateLines[g.id] ?? const [],
    );
  }
}
