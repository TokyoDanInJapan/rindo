import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:rindo/jma/jma_forecast.dart';
import 'package:rindo/screens/radar_map/weather_sheet.dart';

/// The place menu and the weather report it leads to. The emulator covers the
/// integrated map; these guard the parts a rider taps - that the pin keeps a
/// way to clear itself now that tapping it no longer does so directly, and that
/// a failed fetch says something a person can act on rather than showing an
/// empty sheet or a raw exception.

const _at = LatLng(35.421, 140.179);

/// Advance the clock without waiting for quiet.
///
/// [WidgetTester.pumpAndSettle] returns only once no frame is scheduled, and an
/// indeterminate [CircularProgressIndicator] schedules one forever - so any
/// test that asserts on a *loading* state has to pump by hand or it dies on a
/// ten-second timeout that looks like a hang rather than a spinner. Long enough
/// here for the sheet's open animation and the futures behind it.
Future<void> pumpWhileSpinning(WidgetTester t) async {
  for (var i = 0; i < 5; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// Scroll the sheet until [target] exists, or give up.
///
/// The sheet opens part-height and a [ListView] doesn't build what's off
/// screen, so anything below the fold - the week table, the source button -
/// isn't in the tree for a finder to see until it's been scrolled near. Driven
/// by the target rather than a fixed distance so the tests don't have to encode
/// how tall the content happens to be today.
Future<void> revealInSheet(WidgetTester t, Finder target) async {
  for (var i = 0; i < 10 && target.evaluate().isEmpty; i++) {
    await t.drag(find.byType(ListView), const Offset(0, -300));
    await t.pumpAndSettle();
  }
  if (target.evaluate().isNotEmpty) {
    // Being in the tree is not the same as being on screen: a ListView builds
    // a little past the viewport, and a tap aimed at something below the fold
    // lands on nothing at all.
    await t.ensureVisible(target);
    await t.pumpAndSettle();
  }
}

/// Builds a context inside a MaterialApp, since every sheet here is opened
/// imperatively rather than mounted as a widget.
Future<BuildContext> _host(WidgetTester t) async {
  late BuildContext ctx;
  await t.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (c) {
          ctx = c;
          return const SizedBox();
        },
      ),
    ),
  );
  return ctx;
}

WeatherReport _report({
  String? headline,
  List<RainChance> rain = const [],
  List<WeeklyDay>? week,
}) =>
    WeatherReport(
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
      reportedAt: DateTime.utc(2026, 7, 25, 1, 40), // 10:40 JST
      headline: headline,
      overview: '千葉県は、晴れています。',
      days: [
        WeatherDay(
          at: DateTime.utc(2026, 7, 24, 20), // 05:00 JST on the 25th
          weather: '晴れのち雷雨',
          code: '201',
          wind: '北の風',
          wave: '１．５メートル',
          tempMax: 35,
        ),
      ],
      rain: rain,
      week: week ?? _week,
    );

final _week = [
  WeeklyDay(
    at: DateTime.utc(2026, 7, 26, 15), // 27 July JST
    code: '200',
    pop: 30,
    tempMax: 29,
    tempMin: 24,
    reliability: 'C',
  ),
  WeeklyDay(
    at: DateTime.utc(2026, 7, 27, 15),
    code: '101',
    pop: 60,
    tempMax: 31,
    tempMin: 24,
    reliability: 'A',
  ),
];

void main() {
  group('place sheet', () {
    testWidgets('the pin offers weather and a way to clear itself', (t) async {
      final ctx = await _host(t);
      var weather = 0, cleared = 0;
      showPlaceSheet(
        ctx,
        pinned: true,
        onWeather: () => weather++,
        onClearPin: () => cleared++,
      );
      await t.pumpAndSettle();
      expect(find.text('Weather here'), findsOneWidget);
      expect(find.text('Clear pin'), findsOneWidget);

      await t.tap(find.text('Clear pin'));
      await t.pumpAndSettle();
      expect((weather, cleared), (0, 1));
      // The sheet closes behind the action rather than sitting over the map.
      expect(find.text('Weather here'), findsNothing);
    });

    testWidgets('the rider dot offers weather but nothing to clear', (t) async {
      final ctx = await _host(t);
      var weather = 0;
      showPlaceSheet(
        ctx,
        pinned: false,
        onWeather: () => weather++,
        onClearPin: () => fail('there is no pin to clear'),
      );
      await t.pumpAndSettle();
      expect(find.text('Clear pin'), findsNothing);

      await t.tap(find.text('Weather here'));
      await t.pumpAndSettle();
      expect(weather, 1);
    });
  });

  group('weather sheet', () {
    testWidgets('shows a spinner, then the report', (t) async {
      final ctx = await _host(t);
      final gate = Completer<WeatherReport>();
      showWeatherSheet(
        ctx,
        at: _at,
        load: (_) => gate.future,
        onOpenSource: (_) {},
      );
      await t.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      gate.complete(
        _report(
          rain: [
            RainChance(at: DateTime.utc(2026, 7, 24, 21), percent: 10),
            RainChance(at: DateTime.utc(2026, 7, 25, 9), percent: 70),
          ],
        ),
      );
      await t.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('北東部'), findsOneWidget);
      expect(find.textContaining('長柄町'), findsOneWidget);
      // JMA's wording stays a sentence below the table, not a table cell.
      expect(find.text('晴れのち雷雨'), findsOneWidget);
      // Today's high, with no low - JMA echoed it into a past slot, so the
      // parser dropped it and the sheet must not invent one.
      expect(find.text('↑35°'), findsOneWidget);
      expect(find.textContaining('↓'), findsNothing);

      await revealInSheet(t, find.textContaining('銚子地方気象台'));
      expect(find.textContaining('銚子地方気象台'), findsOneWidget);
      expect(find.textContaining('10:40 JST'), findsOneWidget);
    });

    testWidgets('rain chances land in JMA\'s fixed 6-hour columns', (t) async {
      final ctx = await _host(t);
      showWeatherSheet(
        ctx,
        at: _at,
        load: (_) async => _report(
          rain: [
            // 06:00 and 18:00 JST on the 25th; the 00-06 and 12-18 blocks have
            // no entry, which is what JMA does once a block has passed.
            RainChance(at: DateTime.utc(2026, 7, 24, 21), percent: 10),
            RainChance(at: DateTime.utc(2026, 7, 25, 9), percent: 70),
          ],
        ),
        onOpenSource: (_) {},
      );
      await t.pumpAndSettle();

      expect(find.text('06-12'), findsOneWidget);
      expect(find.text('18-00'), findsOneWidget);
      expect(find.text('10'), findsOneWidget);
      expect(find.text('70'), findsOneWidget);
      // Blocks JMA no longer reports read as absent, not as zero - a rider must
      // not see "0%" where the truth is "no longer forecast".
      expect(find.text('0'), findsNothing);
      expect(find.text('–'), findsWidgets);
    });

    testWidgets('rules each section off under its own heading', (t) async {
      final ctx = await _host(t);
      showWeatherSheet(
        ctx,
        at: _at,
        load: (_) async => _report(),
        onOpenSource: (_) {},
      );
      await t.pumpAndSettle();

      // Five blocks that look alike at a glance - two tables of numbers, two
      // runs of Japanese, and the attribution - so each is titled and ruled
      // off from the one above it.
      const sections = [
        'Forecast',
        'Day by day',
        'Week ahead',
        'Outlook',
        'Source',
      ];
      for (final title in sections) {
        await revealInSheet(t, find.text(title));
        expect(find.text(title), findsOneWidget, reason: '$title heading');
        expect(
          find.ancestor(of: find.text(title), matching: find.byType(Column)),
          findsWidgets,
        );
      }
      // One rule per section, and they are real Dividers rather than spacing
      // that only looks like separation on a big screen.
      await revealInSheet(t, find.text('Source'));
      expect(find.byType(Divider), findsWidgets);
    });

    testWidgets('drops the headings for parts JMA did not send', (t) async {
      final ctx = await _host(t);
      showWeatherSheet(
        ctx,
        at: _at,
        load: (_) async => _report(week: const []),
        onOpenSource: (_) {},
      );
      await t.pumpAndSettle();
      // An empty section would be a rule and a title with nothing under them.
      expect(find.text('Week ahead'), findsNothing);
      expect(find.text('Forecast'), findsOneWidget);
    });

    testWidgets('the week ahead is a table of its own', (t) async {
      final ctx = await _host(t);
      showWeatherSheet(
        ctx,
        at: _at,
        load: (_) async => _report(),
        onOpenSource: (_) {},
      );
      await t.pumpAndSettle();
      await revealInSheet(t, find.text('Week ahead'));

      expect(find.text('Week ahead'), findsOneWidget);
      expect(find.text('7/27'), findsOneWidget);
      expect(find.text('7/28'), findsOneWidget);
      expect(find.text('29°'), findsOneWidget); // max
      expect(find.text('24°'), findsWidgets); // min, both days
      // JMA's confidence grade: the difference between planning and hoping.
      expect(find.text('C'), findsOneWidget);
      expect(find.text('A'), findsOneWidget);
    });

    testWidgets('renders an icon per day from JMA\'s weather code', (t) async {
      final ctx = await _host(t);
      showWeatherSheet(
        ctx,
        at: _at,
        load: (_) async => _report(),
        onOpenSource: (_) {},
      );
      await t.pumpAndSettle();
      // 201, today's code, is the くもり family. (The mapping itself is pinned
      // by the weatherIcon unit tests; this only proves the table draws it.)
      expect(find.byIcon(Icons.cloud), findsWidgets);

      await revealInSheet(t, find.byIcon(Icons.sunny));
      // 101 in the week table is the 晴れ family.
      expect(find.byIcon(Icons.sunny), findsWidgets);
    });

    testWidgets('omits the week ahead when JMA sent none', (t) async {
      final ctx = await _host(t);
      showWeatherSheet(
        ctx,
        at: _at,
        load: (_) async => _report(week: const []),
        onOpenSource: (_) {},
      );
      await t.pumpAndSettle();
      expect(find.text('Week ahead'), findsNothing);
      // The near-term table is unaffected.
      expect(find.text('Rain %'), findsOneWidget);
    });

    testWidgets('leads with a JMA headline when there is one', (t) async {
      final ctx = await _host(t);
      showWeatherSheet(
        ctx,
        at: _at,
        load: (_) async => _report(headline: '雷と突風に関する情報'),
        onOpenSource: (_) {},
      );
      await t.pumpAndSettle();
      expect(find.text('雷と突風に関する情報'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber), findsOneWidget);
    });

    testWidgets('stays quiet when there is no headline', (t) async {
      final ctx = await _host(t);
      showWeatherSheet(
        ctx,
        at: _at,
        load: (_) async => _report(),
        onOpenSource: (_) {},
      );
      await t.pumpAndSettle();
      expect(find.byIcon(Icons.warning_amber), findsNothing);
    });

    testWidgets('the source button opens JMA for that office', (t) async {
      final ctx = await _host(t);
      final opened = <Uri>[];
      showWeatherSheet(
        ctx,
        at: _at,
        load: (_) async => _report(),
        onOpenSource: opened.add,
      );
      await t.pumpAndSettle();
      await revealInSheet(t, find.textContaining('気象庁 天気予報'));
      await t.tap(find.textContaining('気象庁 天気予報'));
      await t.pumpAndSettle();
      expect(opened.single.toString(), contains('area_code=120000'));
    });

    testWidgets('a position outside Japan says so, not "error"', (t) async {
      final ctx = await _host(t);
      showWeatherSheet(
        ctx,
        at: const LatLng(51.5, -0.12),
        load: (_) async =>
            throw JmaForecastException('no JMA forecast area covers this'),
        onOpenSource: (_) {},
      );
      await t.pumpAndSettle();
      expect(find.textContaining('only covers Japan'), findsOneWidget);
      expect(find.textContaining('JmaForecastException'), findsNothing);
    });

    testWidgets('a failed fetch blames the connection, not the rider', (
      t,
    ) async {
      final ctx = await _host(t);
      showWeatherSheet(
        ctx,
        at: _at,
        load: (_) async => throw JmaForecastException('forecast 503'),
        onOpenSource: (_) {},
      );
      await t.pumpAndSettle();
      expect(find.textContaining('Check your connection'), findsOneWidget);
      expect(find.textContaining('503'), findsNothing);
    });

    testWidgets('shows the Japanese first, then swaps the English in', (
      t,
    ) async {
      final ctx = await _host(t);
      final model = Completer<WeatherReport>();
      showWeatherSheet(
        ctx,
        at: _at,
        load: (_) async => _report(),
        onOpenSource: (_) {},
        translate: (_) => model.future,
      );
      await pumpWhileSpinning(t);

      // The point of translating in a second step: JMA's own words are on
      // screen while the (possibly ~30 MB) model is still being fetched.
      expect(find.text('晴れのち雷雨'), findsOneWidget);
      expect(find.text('Translating…'), findsOneWidget);

      model.complete(
        WeatherReport(
          area: _report().area,
          areaName: 'North-eastern Region',
          office: 'Choshi Meteorological Observatory',
          reportedAt: _report().reportedAt,
          headline: null,
          overview: 'Chiba is sunny.',
          days: [
            WeatherDay(
              at: _report().days.first.at,
              weather: 'Sunny, then thunderstorms',
              tempMax: 35,
            ),
          ],
          rain: const [],
          week: const [],
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('Sunny, then thunderstorms'), findsOneWidget);
      expect(find.text('晴れのち雷雨'), findsNothing);
      expect(find.text('North-eastern Region'), findsOneWidget);
      expect(find.text('Translating…'), findsNothing);
    });

    testWidgets('keeps the Japanese when translation fails', (t) async {
      final ctx = await _host(t);
      showWeatherSheet(
        ctx,
        at: _at,
        load: (_) async => _report(),
        onOpenSource: (_) {},
        translate: (_) async => throw Exception('model unavailable'),
      );
      await t.pumpAndSettle();

      // Degrading to the source of record beats an error: it's still the
      // forecast, just not in English.
      expect(find.text('晴れのち雷雨'), findsOneWidget);
      expect(find.text('北東部'), findsOneWidget);
      expect(find.text('Translating…'), findsNothing);
      expect(find.textContaining('model unavailable'), findsNothing);
    });

    testWidgets('never mentions translating in Japanese mode', (t) async {
      final ctx = await _host(t);
      showWeatherSheet(
        ctx,
        at: _at,
        load: (_) async => _report(),
        onOpenSource: (_) {},
      );
      await t.pumpAndSettle();
      expect(find.text('Translating…'), findsNothing);
      expect(find.text('晴れのち雷雨'), findsOneWidget);
    });

    testWidgets('fetches once, not once per rebuild', (t) async {
      final ctx = await _host(t);
      var fetches = 0;
      showWeatherSheet(
        ctx,
        at: _at,
        load: (_) async {
          fetches++;
          return _report();
        },
        onOpenSource: (_) {},
      );
      await t.pumpAndSettle();
      // Drag the sheet: DraggableScrollableSheet rebuilds its child as it
      // resizes, which would refetch if the future were created in build().
      await t.drag(find.text('北東部'), const Offset(0, -120));
      await t.pumpAndSettle();
      expect(fetches, 1);
    });
  });
}
