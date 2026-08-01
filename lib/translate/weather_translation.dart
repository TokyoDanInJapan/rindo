import '../jma/jma_forecast.dart';
import 'closure_translator.dart';

/// English display copy of a JMA weather report.
///
/// Two sources, deliberately. Place names come from JMA's own English, baked
/// into forecast_areas.g.dart, and only the free prose goes through ML Kit.
/// Machine translation is at its worst on place names, and 北東部 and 千葉市
/// come back as things a rider has to decode. JMA already publishes
/// 'North-eastern Region' and 'Chiba City' for exactly these codes.
///
/// This never throws and never blocks on a missing model. [ClosureTranslator]
/// degrades each string to its Japanese original, so a model that failed or
/// was never downloaded yields the report unchanged rather than an error. This
/// is the same contract the closure list has had.
Future<WeatherReport> translateReport(
  WeatherReport r,
  ClosureTranslator translator,
) async {
  if (!await translator.ensureReady()) return r;

  Future<String?> maybe(String? ja) async =>
      ja == null ? null : await translator.translateText(ja);

  // The day rows are independent, so translate them concurrently. A report is
  // about 10 short strings, and doing them in series is a visible pause on the
  // first, uncached open.
  final days = await Future.wait(
    r.days.map(
      (d) async => WeatherDay(
        at: d.at,
        weather: await translator.translateText(d.weather),
        code: d.code,
        wind: await maybe(d.wind),
        wave: await maybe(d.wave),
        tempMax: d.tempMax,
        tempMin: d.tempMin,
      ),
    ),
  );
  final headline = await maybe(r.headline);
  final overview = await translator.translateText(r.overview);
  final office = await translator.translateText(r.office);

  return WeatherReport(
    area: ForecastArea(
      // JMA's English, not ML Kit's.
      municipality: r.area.municipalityEn,
      municipalityEn: r.area.municipalityEn,
      class10: r.area.class10,
      class10En: r.area.class10En,
      office: r.area.office,
      km: r.area.km,
    ),
    areaName: r.area.class10En,
    office: office,
    reportedAt: r.reportedAt,
    headline: headline,
    overview: overview,
    days: days,
    rain: r.rain,
    // Codes and numbers, so there is nothing to translate, and the table's
    // labels are already English.
    week: r.week,
  );
}
