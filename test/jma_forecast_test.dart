import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:rindo/jma/jma_forecast.dart';

/// Synthetic Chiba (office 120000) short-term forecast, shaped like the real
/// thing but trimmed. Two subdivisions so area selection has to actually pick
/// one, and the timeSeries are deliberately in an unusual order - JMA has
/// reordered them before, and the client identifies each by the fields its
/// areas carry rather than by position.
///
/// Temperatures reproduce the quirk that drove the pairing logic: a midday
/// issue echoes the day's high into the already-past 00:00 low slot, so
/// 25 July arrives as high 35 / "low" 35.
String _forecastJson({
  bool withTemps = true,
  bool withWaves = true,
  bool thirdDay = false,
}) {
  Map<String, Object?> area(String code, String name, Map<String, Object?> f) =>
      {
        'area': {'name': name, 'code': code},
        ...f,
      };
  return jsonEncode([
    {
      'publishingOffice': '銚子地方気象台',
      'reportDatetime': '2026-07-25T05:00:00+09:00',
      'timeSeries': [
        // pops first, to prove position isn't what identifies a series.
        {
          'timeDefines': [
            '2026-07-25T06:00:00+09:00',
            '2026-07-25T12:00:00+09:00',
            '2026-07-25T18:00:00+09:00',
          ],
          'areas': [
            area('120010', '北西部', {
              'pops': ['10', '20', '50'],
            }),
            area('120020', '北東部', {
              'pops': ['0', '30', '70'],
            }),
          ],
        },
        if (withTemps)
          {
            'timeDefines': [
              '2026-07-25T09:00:00+09:00',
              '2026-07-25T00:00:00+09:00',
              '2026-07-26T00:00:00+09:00',
              '2026-07-26T09:00:00+09:00',
            ],
            'areas': [
              area('45212', '千葉', {
                'temps': ['35', '35', '26', '33'],
              }),
            ],
          },
        {
          'timeDefines': [
            '2026-07-25T05:00:00+09:00',
            '2026-07-26T00:00:00+09:00',
            if (thirdDay) '2026-07-27T00:00:00+09:00',
          ],
          'areas': [
            area('120010', '北西部', {
              'weatherCodes': ['212', '212'],
              'weathers': [
                'くもり　時々　晴れ',
                'くもり　夜　雨',
                if (thirdDay) 'くもり',
              ],
              'winds': ['北西の風　後　南東の風', '西の風'],
              if (withWaves) 'waves': ['０．５メートル', '０．５メートル'],
            }),
            area('120020', '北東部', {
              'weatherCodes': ['201', '212', if (thirdDay) '200'],
              'weathers': ['晴れ　のち　雷雨', 'あめ', if (thirdDay) 'くもり'],
              'winds': ['北の風', '北東の風'],
              if (withWaves) 'waves': ['１．５メートル', '２メートル'],
            }),
          ],
        },
      ],
    },
    // 週間予報: a different shape entirely - one area for the whole office,
    // temperatures at a single observation point, and no wording. JMA repeats
    // the days the detailed block already covers with the fields blanked.
    {
      'publishingOffice': '銚子地方気象台',
      'timeSeries': [
        {
          'timeDefines': [
            '2026-07-25T00:00:00+09:00',
            '2026-07-26T00:00:00+09:00',
            '2026-07-27T00:00:00+09:00',
            '2026-07-28T00:00:00+09:00',
          ],
          'areas': [
            area('120000', '千葉県', {
              'weatherCodes': ['200', '200', '201', '101'],
              'pops': ['', '40', '30', '20'],
              'reliabilities': ['', '', 'C', 'A'],
            }),
          ],
        },
        {
          'timeDefines': [
            '2026-07-25T00:00:00+09:00',
            '2026-07-26T00:00:00+09:00',
            '2026-07-27T00:00:00+09:00',
            '2026-07-28T00:00:00+09:00',
          ],
          'areas': [
            area('45148', '銚子', {
              'tempsMin': ['', '24', '23', '25'],
              'tempsMax': ['', '30', '29', '31'],
            }),
          ],
        },
      ],
    },
  ]);
}

const _overviewJson = '''
{
  "publishingOffice": "銚子地方気象台",
  "reportDatetime": "2026-07-25T10:40:00+09:00",
  "targetArea": "千葉県",
  "headlineText": "",
  "text": "　千葉県は、晴れています。\\n\\n　２５日は、夕方から雷を伴い激しく降るでしょう。"
}
''';

http.Client _fakeJma({
  bool withTemps = true,
  bool withWaves = true,
  bool thirdDay = false,
  String? headline,
  int status = 200,
}) => MockClient((req) async {
  if (status != 200) return http.Response('nope', status);
  if (req.url.path.contains('overview_forecast')) {
    final doc = jsonDecode(_overviewJson) as Map<String, dynamic>;
    if (headline != null) doc['headlineText'] = headline;
    return http.Response.bytes(utf8.encode(jsonEncode(doc)), 200);
  }
  return http.Response.bytes(
    utf8.encode(
      _forecastJson(
        withTemps: withTemps,
        withWaves: withWaves,
        thirdDay: thirdDay,
      ),
    ),
    200,
  );
});

/// Inside 長柄町, north-east Chiba - the camera position from the tile bug
/// report, which resolves to the 120020 subdivision (not the first one listed).
const _inChiba = LatLng(35.421, 140.179);

void main() {
  group('forecastAreaFor', () {
    test('resolves a position to its JMA subdivision and office', () {
      final a = forecastAreaFor(_inChiba)!;
      expect(a.class10, '120020'); // 千葉県北東部
      expect(a.office, '120000');
      expect(a.km, lessThan(20));
      expect(a.municipality, isNotEmpty);
    });

    test('handles the offices that are not just the JIS code + 0000', () {
      // Sapporo: Hokkaido is split seven ways, so 010000 doesn't exist.
      expect(forecastAreaFor(const LatLng(43.062, 141.354))!.office, '016000');
      // Kagoshima's mainland office is 460100, not 460000.
      expect(forecastAreaFor(const LatLng(31.596, 130.557))!.office, '460100');
      // Naha sits under one of Okinawa's four offices.
      expect(forecastAreaFor(const LatLng(26.212, 127.679))!.office, '471000');
    });

    test('gives up rather than guess for a position far outside Japan', () {
      expect(forecastAreaFor(const LatLng(51.5, -0.12)), isNull); // London
      expect(forecastAreaFor(const LatLng(30.0, 150.0)), isNull); // Pacific
    });
  });

  group('fetch', () {
    test('reads the subdivision the position is in, not the first listed',
        () async {
      final r = await JmaForecastApi(client: _fakeJma()).fetch(_inChiba);
      expect(r.areaName, '北東部');
      expect(r.days.first.weather, '晴れのち雷雨'); // ideographic padding stripped
      expect(r.rain.map((p) => p.percent), [0, 30, 70]);
      expect(r.office, '銚子地方気象台');
      expect(r.overview, startsWith('千葉県は、晴れています。'));
      expect(r.sourceUrl.toString(), contains('area_code=120000'));
    });

    test('pairs temperatures by clock time and drops an echoed low', () async {
      final r = await JmaForecastApi(client: _fakeJma()).fetch(_inChiba);
      final (today, tomorrow) = (r.days[0], r.days[1]);
      expect(today.tempMax, 35);
      // JMA echoed 35 into the already-past 00:00 slot; showing it as the
      // day's low would be a lie, so it's dropped.
      expect(today.tempMin, isNull);
      expect(tomorrow.tempMax, 33);
      expect(tomorrow.tempMin, 26);
    });

    test('survives an office that publishes no temperatures or waves',
        () async {
      final r = await JmaForecastApi(
        client: _fakeJma(withTemps: false, withWaves: false),
      ).fetch(_inChiba);
      expect(r.days, isNotEmpty);
      expect(r.days.first.tempMax, isNull);
      expect(r.days.first.wave, isNull);
      expect(r.days.first.wind, isNotEmpty);
    });

    test('surfaces a headline when JMA has one', () async {
      final quiet = await JmaForecastApi(client: _fakeJma()).fetch(_inChiba);
      expect(quiet.headline, isNull, reason: 'empty headlineText is not news');
      final loud = await JmaForecastApi(
        client: _fakeJma(headline: '雷と突風及びひょうに関する情報'),
      ).fetch(_inChiba);
      expect(loud.headline, '雷と突風及びひょうに関する情報');
    });

    test('carries the weather code through for the icon', () async {
      final r = await JmaForecastApi(client: _fakeJma()).fetch(_inChiba);
      expect(r.days.first.code, '201');
      expect(r.days[1].code, '212');
    });

    test('reads the week ahead, minus the days already detailed', () async {
      final r = await JmaForecastApi(client: _fakeJma()).fetch(_inChiba);

      // 25 and 26 July are in `days`; repeating them in the weekly table would
      // say the same thing twice, with worse numbers.
      expect(r.week.map((d) => jstDate(d.at)), [(7, 27), (7, 28)]);
      expect(r.week.map((d) => d.code), ['201', '101']);
      expect(r.week.map((d) => d.pop), [30, 20]);
      expect(r.week.map((d) => d.tempMax), [29, 31]);
      expect(r.week.map((d) => d.tempMin), [23, 25]);
      expect(r.week.map((d) => d.reliability), ['C', 'A']);
    });

    test('keeps a wording-only day in the week table, where it has numbers',
        () async {
      final r = await JmaForecastApi(
        client: _fakeJma(thirdDay: true),
      ).fetch(_inChiba);

      // 27 July appears in the detailed block as wording alone - no
      // temperatures, no rain chance - so the weekly block is the only place
      // its numbers exist. Dropping it as "already covered" would lose them.
      expect(r.days.map((d) => jstDate(d.at)), [(7, 25), (7, 26), (7, 27)]);
      expect(r.days.last.tempMax, isNull);
      final july27 = r.week.firstWhere((d) => jstDate(d.at) == (7, 27));
      expect(july27.tempMax, 29);
      expect(july27.pop, 30);
      // The two days that *do* have detail stay out of the weekly table.
      expect(r.week.map((d) => jstDate(d.at)), isNot(contains((7, 25))));
      expect(r.week.map((d) => jstDate(d.at)), isNot(contains((7, 26))));
    });

    test('leaves the week empty when JMA sends only the short-term block',
        () async {
      final client = MockClient((req) async {
        if (req.url.path.contains('overview_forecast')) {
          return http.Response.bytes(utf8.encode(_overviewJson), 200);
        }
        // A single-block response: seen when an office is mid-update.
        final full = jsonDecode(_forecastJson()) as List;
        return http.Response.bytes(utf8.encode(jsonEncode([full.first])), 200);
      });
      final r = await JmaForecastApi(client: client).fetch(_inChiba);
      expect(r.days, isNotEmpty, reason: 'the detailed forecast still works');
      expect(r.week, isEmpty);
    });

    test('throws for a position JMA does not cover', () async {
      await expectLater(
        JmaForecastApi(client: _fakeJma()).fetch(const LatLng(51.5, -0.12)),
        throwsA(isA<JmaForecastException>()),
      );
    });

    test('throws on a bad response rather than showing a blank report',
        () async {
      await expectLater(
        JmaForecastApi(client: _fakeJma(status: 503)).fetch(_inChiba),
        throwsA(isA<JmaForecastException>()),
      );
    });
  });

  group('jst helpers', () {
    test('render a UTC instant on Japan clock', () {
      final utc = DateTime.utc(2026, 7, 25, 0, 30); // 09:30 JST
      expect(jstHhmm(utc), '09:30');
      expect(jstDate(utc), (7, 25));
    });

    test('roll the date over at the JST day boundary', () {
      final utc = DateTime.utc(2026, 7, 25, 15, 5); // 00:05 JST on the 26th
      expect(jstHhmm(utc), '00:05');
      expect(jstDate(utc), (7, 26));
    });
  });
}
