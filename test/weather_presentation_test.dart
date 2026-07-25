import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rindo/screens/radar_map/weather_presentation.dart';

/// JMA publishes ~130 天気コード but no machine-readable table for them, so the
/// icon is derived from the leading digit alone (1 晴れ, 2 くもり, 3 雨, 4 雪).
/// That rule was checked against live data from ten offices - 87 of 87 periods
/// agreed with JMA's own wording - and these pin it so a future edit can't
/// quietly regress the whole thing to a default icon.

void main() {
  group('weatherIcon', () {
    test('maps each family by its leading digit', () {
      // Real codes seen in live responses.
      expect(weatherIcon('100'), Icons.sunny); // 晴
      expect(weatherIcon('101'), Icons.sunny); // 晴時々くもり
      expect(weatherIcon('200'), Icons.cloud); // くもり
      expect(weatherIcon('212'), Icons.cloud); // くもり後一時雨
      expect(weatherIcon('300'), Icons.water_drop); // 雨
      expect(weatherIcon('400'), Icons.ac_unit); // 雪
    });

    test('says nothing rather than guessing when there is no code', () {
      // The weekly table's near days carry an empty code; a wrong icon there
      // would read as a forecast JMA never made.
      expect(weatherIcon(null), Icons.remove);
      expect(weatherIcon(''), Icons.remove);
      expect(weatherIcon('   '), Icons.remove);
      // A family JMA has never used.
      expect(weatherIcon('900'), Icons.remove);
    });

    test('tolerates padding around the code', () {
      expect(weatherIcon(' 201 '), Icons.cloud);
    });
  });

  group('weatherColor', () {
    testWidgets('gives each family its own colour and greys the unknown', (
      t,
    ) async {
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

      final colours = {
        for (final code in ['100', '200', '300', '400'])
          code: weatherColor(code, ctx),
      };
      expect(
        colours.values.toSet(),
        hasLength(4),
        reason: 'four families, four colours - otherwise the icon carries it '
            'alone and a wet day looks like a dry one',
      );
      expect(weatherColor(null, ctx), Theme.of(ctx).disabledColor);
    });
  });
}
