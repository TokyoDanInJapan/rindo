import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import '../hazards/municipalities.g.dart';
import 'forecast_areas.g.dart';

/// Direct client for JMA's 天気予報 (area forecast) endpoints, the ones behind
/// https://www.jma.go.jp/bosai/forecast/. Like the nowcast endpoints in
/// jma_api.dart, these are undocumented and can change without notice. When
/// the weather sheet breaks, this is the file to touch.
///
///   forecast:  .../bosai/forecast/data/forecast/{office}.json
///     -> [shortTerm, weekly], each a bag of 'timeSeries' whose entries pair a
///        timeDefines list with per-area arrays of the same length
///   overview:  .../bosai/forecast/data/overview_forecast/{office}.json
///     -> { publishingOffice, reportDatetime, targetArea, headlineText, text }
///
/// Both blocks are read. The weekly block has a different shape from the
/// short-term one: a single area per series rather than one per subdivision,
/// with confidence grades and no wording.
///
/// Everything is keyed by JMA area code, never by coordinates, so a position
/// must be resolved first. See [forecastAreaFor].
const jmaForecastBase = 'https://www.jma.go.jp/bosai/forecast/data';

/// The JMA area a position falls in, plus the municipality that resolved it.
///
/// A report is only ever *for* an area, so the sheet names the municipality it
/// matched. '南部 (館山市 near you)' is honest in a way that a bare subdivision
/// name is not, especially when the nearest town is some way off.
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

  /// JMA class10 subdivision code. This is the granularity the weather text is
  /// written at (120010 = 千葉県北西部).
  final String class10;

  /// JMA office code, which names the file both endpoints are keyed by
  /// (120000).
  final String office;

  /// How far the matched municipality's office is from the query point.
  final double km;
}

/// Nearest municipality with a JMA forecast area, or null outside Japan.
///
/// A straight nearest-neighbour scan over the baked table: about 1700 rows,
/// one pass, no allocation per row. Point-in-polygon against the real
/// subdivision boundaries would be more correct near a border, but those
/// boundaries are not published in a form worth shipping. A forecast
/// subdivision is coarse enough that the nearest town is the right answer
/// nearly everywhere.
///
/// [maxKm] rejects a position that resolves to something absurdly far away. A
/// camera parked over the Pacific should not confidently report Chiba's
/// weather.
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
/// that day. Every field except [at] and [weather] can be absent. Inland
/// subdivisions carry no wave height. Temperatures come from a separate series
/// keyed by observation point, so they do not always line up.
class WeatherDay {
  const WeatherDay({
    required this.at,
    required this.weather,
    this.code,
    this.wind,
    this.wave,
    this.tempMax,
    this.tempMin,
  });

  /// Start of the forecast period, as a UTC instant (see [jstHhmm]).
  final DateTime at;
  final String weather;

  /// JMA's 3-digit 天気コード, for the icon (see weather_presentation.dart).
  final String? code;

  final String? wind;
  final String? wave;
  final int? tempMax;
  final int? tempMin;
}

/// One day of the 週間予報: numbers and a code, no prose. JMA does not write
/// wording this far out, which is why the weekly view is a table on its page
/// and a table here.
class WeeklyDay {
  const WeeklyDay({
    required this.at,
    this.code,
    this.pop,
    this.tempMax,
    this.tempMin,
    this.reliability,
  });

  final DateTime at;
  final String? code;

  /// Chance of rain across the whole day, not a 6-hour block.
  final int? pop;
  final int? tempMax;
  final int? tempMin;

  /// JMA's confidence grade, A (highest) to C. It is worth showing, because it
  /// is the difference between planning on a forecast and hoping.
  final String? reliability;
}

/// Chance of rain in one 6-hour block: the number a rider actually plans on.
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
    required this.week,
  });

  final ForecastArea area;

  /// JMA's name for the subdivision (北西部), from the response rather than a
  /// baked table, so a renamed area cannot go stale here.
  final String areaName;

  /// Issuing office as JMA names it (銚子地方気象台).
  final String office;
  final DateTime reportedAt;

  /// JMA's warning headline. It is usually absent. When it is present, it is
  /// the thing to read first, so the sheet leads with it.
  final String? headline;

  /// The prose forecast for the whole prefecture.
  final String overview;

  final List<WeatherDay> days;
  final List<RainChance> rain;

  /// The week beyond [days]. Days already covered in detail are left out, so
  /// the two tables do not say the same thing twice.
  final List<WeeklyDay> week;

  /// JMA's own page for this area, for the 'read it on JMA' link.
  Uri get sourceUrl => Uri.parse(
    'https://www.jma.go.jp/bosai/forecast/'
    '#area_type=offices&area_code=${area.office}',
  );
}

/// 'HH:MM' in JST for a UTC instant. Same convention as [JmaFrame.jstLabel].
/// The app covers Japan only, so it shows times on Japan's clock whatever the
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

/// JST hour for a UTC instant: which 6-hour block a rain chance belongs to.
int jstHour(DateTime utc) => utc.toUtc().add(const Duration(hours: 9)).hour;

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
    return _parse(
      area,
      forecast.first,
      forecast.length > 1 ? forecast[1] : null,
      overview,
    );
  }

  WeatherReport _parse(
    ForecastArea area,
    Object? shortTerm,
    Object? weekly,
    Map<String, dynamic> overview,
  ) {
    if (shortTerm is! Map) {
      throw JmaForecastException('forecast: unexpected shape');
    }
    final series = shortTerm['timeSeries'];
    if (series is! List) throw JmaForecastException('forecast: no timeSeries');

    // The series are identified by which fields their areas carry, not by
    // position. JMA has reordered them before, and an office with no coastline
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
      // Only days that the detailed block actually put numbers against are
      // held back. Its last day is routinely wording alone, with no
      // temperatures and no rain chance, and the weekly block *does* have
      // those. Treating 'is mentioned above' as 'is covered above' would throw
      // them away.
      week: _week(weekly, area.office, {
        for (final d in days)
          if (d.tempMax != null) jstDate(d.at),
      }),
    );
  }

  /// The 週間予報 block. It is shaped unlike the short-term one: a single area
  /// per series rather than one per subdivision, and no wording at all. That
  /// single area is the whole office, with one observation point for the
  /// temperatures.
  ///
  /// [covered] are the JST days that the detailed tables already show. JMA
  /// repeats them here with the fields blanked out, so dropping them keeps the
  /// weekly table to what it actually adds.
  List<WeeklyDay> _week(
    Object? weekly,
    String office,
    Set<(int, int)> covered,
  ) {
    if (weekly is! Map) return const [];
    final series = weekly['timeSeries'];
    if (series is! List) return const [];

    final outlook = _seriesWith(series, 'weatherCodes');
    final temps = _seriesWith(series, 'tempsMax');
    final times = _times(outlook);
    final a = _areaFor(outlook, office);
    final codes = _strings(a?['weatherCodes']);
    final pops = _strings(a?['pops']);
    final grades = _strings(a?['reliabilities']);

    // Temperatures ride their own timeDefines and are keyed by observation
    // point, so index by day rather than trusting the two series to align.
    final t = _areaFor(temps, office);
    final tempTimes = _times(temps);
    final maxes = _strings(t?['tempsMax']);
    final mins = _strings(t?['tempsMin']);
    final byDay = <(int, int), (int?, int?)>{};
    for (var i = 0; i < tempTimes.length; i++) {
      byDay[jstDate(tempTimes[i])] = (
        i < mins.length ? int.tryParse(mins[i]) : null,
        i < maxes.length ? int.tryParse(maxes[i]) : null,
      );
    }

    final out = <WeeklyDay>[];
    for (var i = 0; i < times.length; i++) {
      final day = jstDate(times[i]);
      if (covered.contains(day)) continue;
      final (min, max) = byDay[day] ?? (null, null);
      final grade = i < grades.length ? grades[i].trim() : '';
      out.add(
        WeeklyDay(
          at: times[i],
          code: i < codes.length && codes[i].isNotEmpty ? codes[i] : null,
          pop: i < pops.length ? int.tryParse(pops[i]) : null,
          tempMax: max,
          tempMin: min,
          reliability: grade.isEmpty ? null : grade,
        ),
      );
    }
    return out;
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

  /// The entry for [code] in a series, or the first entry as a fallback. A
  /// temperature series is keyed by observation point, which never matches a
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
    final codes = _strings(a['weatherCodes']);
    final winds = _strings(a['winds']);
    final waves = _strings(a['waves']);

    // Temperatures come as a flat list against their own timeDefines, so pair
    // them by clock time rather than by index. The 00:00 slot is the day's low
    // and the 09:00 slot is its high. Reading them positionally breaks
    // whenever JMA drops the already-past morning low from a midday issue.
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
            code: i < codes.length && codes[i].isNotEmpty ? codes[i] : null,
            wind: i < winds.length ? _tidy(winds[i]) : null,
            wave: i < waves.length ? _tidy(waves[i]) : null,
            // A 'low' equal to the high is JMA echoing the high into a slot
            // that has already passed. Showing it as a low would be a lie.
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
  /// (`くもり　時々　晴れ`). Its own site renders them closed up, and so should
  /// this app. Blank lines in the prose are kept, because they are paragraph
  /// breaks.
  String _tidy(String s) => s.replaceAll('　', '').trim();
}

/// JMA's forecast endpoints returned something unusable, or the position is
/// not one they cover.
class JmaForecastException implements Exception {
  JmaForecastException(this.message);
  final String message;
  @override
  String toString() => 'JmaForecastException: $message';
}
