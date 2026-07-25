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

WeatherReport _report({String? headline, List<RainChance> rain = const []}) =>
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
          wind: '北の風',
          wave: '１．５メートル',
          tempMax: 35,
        ),
      ],
      rain: rain,
    );

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
      expect(find.text('晴れのち雷雨'), findsOneWidget);
      // Today's high, with no low - JMA echoed it into a past slot, so the
      // parser dropped it and the sheet must not invent one.
      expect(find.textContaining('↑35°'), findsOneWidget);
      expect(find.textContaining('↓'), findsNothing);
      // Rain chances render on Japan's clock, not the test machine's.
      expect(find.text('06:00 10%'), findsOneWidget);
      expect(find.text('18:00 70%'), findsOneWidget);
      expect(find.textContaining('銚子地方気象台'), findsOneWidget);
      expect(find.textContaining('10:40 JST'), findsOneWidget);
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
