import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:rindo/jma/jma_forecast.dart';
import 'package:rindo/translate/closure_translator.dart';
import 'package:rindo/translate/weather_translation.dart';

/// The division of labour: place names come from JMA's own English (baked into
/// forecast_areas.g.dart), everything else from the on-device model. Machine
/// translation is worst exactly where JMA is already authoritative, so a
/// regression that sent 北東部 through ML Kit would be a quiet downgrade.

/// Deterministic, no platform channels: "translates" by prefixing, and records
/// what it was asked to translate.
class _FakeTranslator extends ClosureTranslator {
  _FakeTranslator({this.ready = true});

  final bool ready;
  final asked = <String>[];

  @override
  Future<bool> ensureReady() async => ready;

  @override
  Future<String> translateText(String ja) async {
    asked.add(ja);
    return 'EN:$ja';
  }
}

WeatherReport _report({String? headline}) => WeatherReport(
  area: const ForecastArea(
    municipality: '長柄町',
    municipalityEn: 'Nagara Town',
    class10: '120020',
    class10En: 'North-eastern Region',
    office: '120000',
    km: 4.0,
  ),
  areaName: '北東部',
  office: '銚子地方気象台',
  reportedAt: DateTime.utc(2026, 7, 25, 1, 40),
  headline: headline,
  overview: '千葉県は、晴れています。',
  days: [
    WeatherDay(
      at: DateTime.utc(2026, 7, 24, 20),
      weather: '晴れのち雷雨',
      wind: '北の風',
      wave: '１．５メートル',
      tempMax: 35,
    ),
    WeatherDay(at: DateTime.utc(2026, 7, 25, 15), weather: 'くもり'),
  ],
  rain: [RainChance(at: DateTime.utc(2026, 7, 24, 21), percent: 10)],
  week: [
    WeeklyDay(at: _weekDay, code: '200', pop: 30, tempMax: 29, tempMin: 24),
  ],
);

final _weekDay = DateTime.utc(2026, 7, 26, 15);

void main() {
  test('place names come from JMA, not the model', () async {
    final tr = _FakeTranslator();
    final out = await translateReport(_report(), tr);

    expect(out.areaName, 'North-eastern Region');
    expect(out.area.municipality, 'Nagara Town');
    // The giveaway that ML Kit was handed a place name would be an EN: prefix.
    expect(out.areaName, isNot(startsWith('EN:')));
    expect(out.area.municipality, isNot(startsWith('EN:')));
    expect(tr.asked, isNot(contains('北東部')));
    expect(tr.asked, isNot(contains('長柄町')));
  });

  test('prose and per-day text go through the model', () async {
    final out = await translateReport(_report(headline: '雷注意'), _FakeTranslator());

    expect(out.overview, 'EN:千葉県は、晴れています。');
    expect(out.headline, 'EN:雷注意');
    expect(out.office, 'EN:銚子地方気象台');
    expect(out.days.first.weather, 'EN:晴れのち雷雨');
    expect(out.days.first.wind, 'EN:北の風');
    expect(out.days.first.wave, 'EN:１．５メートル');
  });

  test('leaves the numbers and times exactly as fetched', () async {
    final source = _report();
    final out = await translateReport(source, _FakeTranslator());

    expect(out.days.first.tempMax, 35);
    expect(out.days.first.at, source.days.first.at);
    expect(out.reportedAt, source.reportedAt);
    expect(out.rain.single.percent, 10);
    expect(out.area.km, 4.0);
    // The source link is derived from the office code, which must survive.
    expect(out.sourceUrl, source.sourceUrl);
  });

  test('absent fields stay absent rather than becoming "EN:null"', () async {
    final out = await translateReport(_report(), _FakeTranslator());
    expect(out.headline, isNull);
    expect(out.days[1].wind, isNull);
    expect(out.days[1].wave, isNull);
  });

  test('an unavailable model yields the Japanese untouched', () async {
    final tr = _FakeTranslator(ready: false);
    final source = _report();
    final out = await translateReport(source, tr);

    expect(identical(out, source), isTrue);
    expect(tr.asked, isEmpty, reason: 'nothing to translate without a model');
  });

  test('the real table backs the English names it promises', () {
    // Guards the generator: if forecast_areas.g.dart ever regenerates without
    // enNames, translation silently falls back to Japanese place names.
    final chiba = forecastAreaFor(const LatLng(35.421, 140.179))!;
    expect(chiba.class10En, 'North-eastern Region');
    expect(chiba.municipalityEn, isNotEmpty);
    expect(chiba.municipalityEn, isNot(chiba.municipality));

    final sapporo = forecastAreaFor(const LatLng(43.062, 141.354))!;
    expect(sapporo.class10En, 'Ishikari Region');
    expect(sapporo.municipalityEn, 'Sapporo City');
  });
}
