import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:rindo/jma/jma_api.dart';

/// Synthetic targetTimes for an analysis anchored at 2026-07-13 12:00 UTC.
/// N1: analysis frames every 5 min for the past hour (newest-first, to prove
/// the defensive sort). N2: forecasts +5..+60 min sharing the anchor basetime.
http.Client _fakeJma({
  bool emptyForecast = false,
  List<String> drop = const [],
}) {
  const anchor = '20260713120000';
  final observed = [
    for (var m = 0; m <= 60; m += 5)
      {
        'basetime': _minus(anchor, m),
        'validtime': _minus(anchor, m),
        'elements': ['hrpns'],
      },
  ];
  final forecast = [
    if (!emptyForecast)
      for (var m = 60; m >= 5; m -= 5)
        {
          'basetime': anchor,
          'validtime': _minus(anchor, -m),
          'elements': ['hrpns'],
        },
  ];
  return MockClient((req) async {
    final body = req.url.path.endsWith('targetTimes_N1.json')
        ? observed
        : forecast;
    final filtered = body.where((t) => !drop.contains(t['validtime'])).toList();
    return http.Response(jsonEncode(filtered), 200);
  });
}

String _minus(String jmaTime, int minutes) =>
    formatJmaTime(parseJmaTime(jmaTime).subtract(Duration(minutes: minutes)));

void main() {
  test('assembles the -15..+60 window oldest-first', () async {
    final frames = await JmaApi(client: _fakeJma()).getFrames();
    expect(frames.map((f) => f.offsetMin), [-15, 0, 15, 30, 45, 60]);
    expect(frames.map((f) => f.validtime).toList(), [
      '20260713114500',
      '20260713120000',
      '20260713121500',
      '20260713123000',
      '20260713124500',
      '20260713130000',
    ]);
    // Forecast frames share the analysis basetime; observed are self-based.
    expect(frames[0].basetime, frames[0].validtime);
    expect(frames.last.basetime, '20260713120000');
    expect(frames.last.isForecast, isTrue);
  });

  test('skips offsets JMA has no frame for', () async {
    final frames = await JmaApi(
      client: _fakeJma(drop: ['20260713123000']),
    ).getFrames();
    expect(frames.map((f) => f.offsetMin), [-15, 0, 15, 45, 60]);
  });

  test('falls back to newest observed when forecast is empty', () async {
    final frames = await JmaApi(
      client: _fakeJma(emptyForecast: true),
    ).getFrames();
    expect(frames.map((f) => f.offsetMin), [-15, 0]);
    expect(frames.last.validtime, '20260713120000');
  });

  test('tile URL matches JMA hrpns scheme', () {
    const f = JmaFrame(
      basetime: '20260713120000',
      validtime: '20260713123000',
      offsetMin: 30,
    );
    expect(
      f.urlTemplate,
      'https://www.jma.go.jp/bosai/jmatile/data/nowc/20260713120000/none/'
      '20260713123000/surf/hrpns/{z}/{x}/{y}.png',
    );
  });

  test('jmaNativeZoom pins fetches to the even levels JMA renders', () {
    // Even camera zooms fetch themselves; odd ones snap to the nearest
    // even level (never a blank z5/7/9); out-of-range clamps to 4..10.
    expect(jmaNativeZoom(4.0), 4);
    expect(jmaNativeZoom(4.9), 4);
    expect(jmaNativeZoom(5.0), 6);
    expect(jmaNativeZoom(6.3), 6);
    expect(jmaNativeZoom(7.0), 8);
    expect(jmaNativeZoom(8.9), 8);
    expect(jmaNativeZoom(9.0), 10);
    expect(jmaNativeZoom(10.0), 10);
    expect(jmaNativeZoom(3.0), 4); // map minZoom is 5, but stay safe
    expect(jmaNativeZoom(17.0), 10); // street-level over-zooms z10
  });

  test('JST label converts UTC+9 and wraps midnight', () {
    const f = JmaFrame(
      basetime: '20260713183000',
      validtime: '20260713183000',
      offsetMin: 0,
    );
    expect(f.jstLabel, '03:30');
  });
}
