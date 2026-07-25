import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../hazards/municipalities.g.dart';
import 'forecast_areas.g.dart';

/// Direct client for JMA's 天気予報 (area forecast) endpoints - the ones behind
/// https://www.jma.go.jp/bosai/forecast/. Like the nowcast endpoints in
/// jma_api.dart these are undocumented and may change without notice; when the
/// weather sheet breaks, this is the file to touch.
///
///   forecast:  .../bosai/forecast/data/forecast/{office}.json
///     -> [shortTerm, weekly], each a bag of "timeSeries" whose entries pair a
///        timeDefines list with per-area arrays of the same length
///   overview:  .../bosai/forecast/data/overview_forecast/{office}.json
///     -> { publishingOffice, reportDatetime, targetArea, headlineText, text }
///
/// Only the short-term block is read. The weekly block is a different shape
/// (per-office rather than per-subdivision, with confidence grades) and says
/// little a rider heading out now can act on.
///
/// Everything is keyed by JMA area code, never by coordinates, so a position
/// has to be resolved first - see [forecastAreaFor].
const jmaForecastBase = 'https://www.jma.go.jp/bosai/forecast/data';

/// The JMA area a position falls in, plus the municipality that resolved it.
///
/// Reports are only ever *for* an area, so the sheet names the municipality it
/// matched: "南部 (館山市 near you)" is honest in a way that a bare subdivision
/// name isn't, especially when the nearest town is some way off.
class ForecastArea {
  const ForecastArea({
    required this.municipality,
    required this.municipalityEn,
    required this.class10,
    required this.class10En,
    required this.office,
    required this.km,
  });

  /// Name of the municipality the position resolved through (千葉市).
  final String municipality;

  /// JMA's own English for it (Chiba City). Place names are exactly where
  /// machine translation reads worst, so the baked table wins over ML Kit.
  final String municipalityEn;

  /// JMA's own English for the subdivision (North-eastern Region).
  final String class10En;

  /// JMA class10 subdivision code - the granularity weather text is written
  /// at (120010 = 千葉県北西部).
  final String class10;

  /// JMA office code - the file both endpoints are keyed by (120000).
  final String office;

  /// How far the matched municipality's office is from the query point.
  final double km;
}

/// Nearest municipality with a JMA forecast area, or null outside Japan.
///
/// A straight nearest-neighbour scan over the baked table (~1700 rows, one
/// pass, no allocation per row). Point-in-polygon against the real subdivision
/// boundaries would be more correct near a border, but those boundaries aren't
/// published in a form worth shipping, and a forecast subdivision is coarse
/// enough that the nearest town is the right answer nearly everywhere.
///
/// [maxKm] rejects positions that resolve to something absurdly far away - a
/// camera parked over the Pacific shouldn't confidently report Chiba's weather.
ForecastArea? forecastAreaFor(LatLng at, {double maxKm = 150}) {
  const dist = Distance();
  String? bestCode;
  var bestKm = double.infinity;
  for (final entry in forecastAreas.entries) {
    final m = municipalities[entry.key];
    if (m == null) continue;
    final (_, lat, lon) = m;
    final km = dist.as(LengthUnit.Kilometer, at, LatLng(lat, lon));
    if (km < bestKm) {
      bestKm = km;
      bestCode = entry.key;
    }
  }
  if (bestCode == null || bestKm > maxKm) return null;
  final (class10, office, class10En, municipalityEn) = forecastAreas[bestCode]!;
  return ForecastArea(
    municipality: municipalities[bestCode]!.$1,
    municipalityEn: municipalityEn,
    class10: class10,
    class10En: class10En,
    office: office,
    km: bestKm,
  );
}

/// One forecast day: JMA's own wording, plus whatever else it published for
/// that day. Every field but [at] and [weather] can be absent - inland
/// subdivisions carry no wave height, and temperatures come from a separate
/// series keyed by observation point, so they don't always line up.
class WeatherDay {
  const WeatherDay({
    required this.at,
    required this.weather,
    this.wind,
    this.wave,
    this.tempMax,
    this.tempMin,
  });

  /// Start of the forecast period, as a UTC instant (see [jstHhmm]).
  final DateTime at;
  final String weather;
  final String? wind;
  final String? wave;
  final int? tempMax;
  final int? tempMin;
}

/// Chance of rain in one 6-hour block - the number a rider actually plans on.
class RainChance {
  const RainChance({required this.at, required this.percent});
  final DateTime at;
  final int percent;
}

class WeatherReport {
  const WeatherReport({
    required this.area,
    required this.areaName,
    required this.office,
    required this.reportedAt,
    required this.headline,
    required this.overview,
    required this.days,
    required this.rain,
  });

  final ForecastArea area;

  /// JMA's name for the subdivision (北西部), from the response rather than a
  /// baked table, so a renamed area can't go stale here.
  final String areaName;

  /// Issuing office as JMA names it (銚子地方気象台).
  final String office;
  final DateTime reportedAt;

  /// JMA's warning headline. Usually absent; when present it's the thing to
  /// read first, so the sheet leads with it.
  final String? headline;

  /// The prose forecast for the whole prefecture.
  final String overview;

  final List<WeatherDay> days;
  final List<RainChance> rain;

  /// JMA's own page for this area, for the "read it on JMA" link.
  Uri get sourceUrl => Uri.parse(
    'https://www.jma.go.jp/bosai/forecast/'
    '#area_type=offices&area_code=${area.office}',
  );
}

/// "HH:MM" in JST for a UTC instant. Same convention as [JmaFrame.jstLabel]:
/// the app is Japan-only, so times are shown in Japan's clock whatever the
/// phone is set to.
String jstHhmm(DateTime utc) {
  final jst = utc.toUtc().add(const Duration(hours: 9));
  return '${jst.hour.toString().padLeft(2, '0')}:'
      '${jst.minute.toString().padLeft(2, '0')}';
}

/// JST calendar day for a UTC instant, as a plain (month, day) pair.
(int, int) jstDate(DateTime utc) {
  final jst = utc.toUtc().add(const Duration(hours: 9));
  return (jst.month, jst.day);
}

class JmaForecastApi {
  JmaForecastApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<Map<String, dynamic>> _getObject(String url) async {
    final decoded = await _get(url);
    if (decoded is! Map) throw JmaForecastException('$url: unexpected shape');
    return decoded.cast<String, dynamic>();
  }

  Future<dynamic> _get(String url) async {
    final r = await _client
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 15));
    if (r.statusCode != 200) {
      throw JmaForecastException('forecast ${r.statusCode}');
    }
    return jsonDecode(utf8.decode(r.bodyBytes));
  }

  /// Fetch the report covering [at]. Throws [JmaForecastException] if the
  /// position is outside Japan or JMA returns something unusable.
  Future<WeatherReport> fetch(LatLng at) async {
    final area = forecastAreaFor(at);
    if (area == null) {
      throw JmaForecastException('no JMA forecast area covers this position');
    }
    // One round trip each, in parallel: the prose and the structured series
    // live in different files.
    final results = await Future.wait([
      _get('$jmaForecastBase/forecast/${area.office}.json'),
      _getObject('$jmaForecastBase/overview_forecast/${area.office}.json'),
    ]);
    final forecast = results[0];
    final overview = results[1] as Map<String, dynamic>;
    if (forecast is! List || forecast.isEmpty) {
      throw JmaForecastException('forecast: unexpected shape');
    }
    return _parse(area, forecast.first, overview);
  }

  WeatherReport _parse(
    ForecastArea area,
    Object? shortTerm,
    Map<String, dynamic> overview,
  ) {
    if (shortTerm is! Map) {
      throw JmaForecastException('forecast: unexpected shape');
    }
    final series = shortTerm['timeSeries'];
    if (series is! List) throw JmaForecastException('forecast: no timeSeries');

    // The series are identified by which fields their areas carry, not by
    // position: JMA has reordered them before, and an office with no coastline
    // simply omits some.
    final weather = _seriesWith(series, 'weathers');
    final pops = _seriesWith(series, 'pops');
    final temps = _seriesWith(series, 'temps');

    final days = _days(weather, temps, area.class10);
    if (days.isEmpty) {
      throw JmaForecastException('forecast: no entries for ${area.class10}');
    }

    final areaName =
        _areaFor(weather, area.class10)?['area']?['name'] as String? ??
        area.municipality;
    final headline = (overview['headlineText'] as String? ?? '').trim();

    return WeatherReport(
      area: area,
      areaName: areaName,
      office: overview['publishingOffice'] as String? ?? '気象庁',
      reportedAt:
          DateTime.tryParse(overview['reportDatetime'] as String? ?? '')
              ?.toUtc() ??
          DateTime.now().toUtc(),
      headline: headline.isEmpty ? null : headline,
      overview: _tidy(overview['text'] as String? ?? ''),
      days: days,
      rain: _rain(pops, area.class10),
    );
  }

  /// First timeSeries whose areas carry [field].
  Map<String, dynamic>? _seriesWith(List<dynamic> series, String field) {
    for (final s in series) {
      if (s is! Map) continue;
      final areas = s['areas'];
      if (areas is! List || areas.isEmpty) continue;
      final first = areas.first;
      if (first is Map && first.containsKey(field)) {
        return s.cast<String, dynamic>();
      }
    }
    return null;
  }

  /// The entry for [code] in a series, or the first entry as a fallback -
  /// temperature series are keyed by observation point, which never matches a
  /// class10 code, and one prefectural number beats showing none.
  Map<String, dynamic>? _areaFor(Map<String, dynamic>? series, String code) {
    final areas = series?['areas'];
    if (areas is! List || areas.isEmpty) return null;
    for (final a in areas) {
      if (a is Map && '${(a['area'] as Map?)?['code']}' == code) {
        return a.cast<String, dynamic>();
      }
    }
    return (areas.first as Map).cast<String, dynamic>();
  }

  List<DateTime> _times(Map<String, dynamic>? series) => [
    for (final t in (series?['timeDefines'] as List? ?? const []))
      if (DateTime.tryParse('$t') case final d?) d.toUtc(),
  ];

  List<WeatherDay> _days(
    Map<String, dynamic>? weather,
    Map<String, dynamic>? temps,
    String class10,
  ) {
    final times = _times(weather);
    final a = _areaFor(weather, class10);
    if (a == null) return const [];
    final texts = _strings(a['weathers']);
    final winds = _strings(a['winds']);
    final waves = _strings(a['waves']);

    // Temperatures come as a flat list against their own timeDefines, so pair
    // them by clock time rather than by index: the 00:00 slot is the day's low
    // and the 09:00 slot its high. Reading them positionally breaks whenever
    // JMA drops the already-past morning low from a midday issue.
    final byDay = <(int, int), (int?, int?)>{};
    final tempTimes = _times(temps);
    final tempVals = _strings(_areaFor(temps, class10)?['temps']);
    for (var i = 0; i < tempTimes.length && i < tempVals.length; i++) {
      final v = int.tryParse(tempVals[i]);
      if (v == null) continue;
      final key = jstDate(tempTimes[i]);
      final (min, max) = byDay[key] ?? (null, null);
      final isLow = tempTimes[i].toUtc().add(const Duration(hours: 9)).hour < 6;
      byDay[key] = isLow ? (v, max) : (min, v);
    }

    return [
      for (var i = 0; i < times.length && i < texts.length; i++)
        () {
          final (min, max) = byDay[jstDate(times[i])] ?? (null, null);
          return WeatherDay(
            at: times[i],
            weather: _tidy(texts[i]),
            wind: i < winds.length ? _tidy(winds[i]) : null,
            wave: i < waves.length ? _tidy(waves[i]) : null,
            // A "low" equal to the high is JMA echoing the high into a slot
            // that has already passed; showing it as a low would be a lie.
            tempMin: min == max ? null : min,
            tempMax: max,
          );
        }(),
    ];
  }

  List<RainChance> _rain(Map<String, dynamic>? pops, String class10) {
    final times = _times(pops);
    final values = _strings(_areaFor(pops, class10)?['pops']);
    return [
      for (var i = 0; i < times.length && i < values.length; i++)
        if (int.tryParse(values[i]) case final p?)
          RainChance(at: times[i], percent: p),
    ];
  }

  List<String> _strings(Object? raw) => [
    if (raw is List)
      for (final v in raw) '$v',
  ];

  /// JMA pads its text with ideographic spaces as word separators
  /// (`くもり　時々　晴れ`); its own site renders them closed up, and so should
  /// we. Blank lines in the prose are kept - they're paragraph breaks.
  String _tidy(String s) => s.replaceAll('　', '').trim();
}

/// JMA's forecast endpoints returned something unusable, or the position isn't
/// one they cover.
class JmaForecastException implements Exception {
  JmaForecastException(this.message);
  final String message;
  @override
  String toString() => 'JmaForecastException: $message';
}
