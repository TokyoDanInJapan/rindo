import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:rindo/closures/feed_result.dart';
import 'package:rindo/closures/jartic_source.dart';
import 'package:rindo/closures/mlit_source.dart';
import 'package:rindo/closures/search_area.dart';
import 'package:rindo/hazards/landslide_source.dart';

final _japan = CircleArea(const LatLng(36, 138), 3000);
// The live feeds publish each update under a new path: a new JARTIC target, a
// new MLIT backup directory. The sources reuse a file fetched under the same
// path, so these fakes hand out a new path for every discovery request.
var _snapshot = 0;
String _backup() =>
    '<script src="../backup/${20260713225000 + _snapshot++}/x/init.js">';
Map<String, String> _target() => {'target': 'now${_snapshot++}'};
final _feature = <String, dynamic>{
  'properties': {
    'cs': '01',
    'rd': '通行止',
    'r': '国道１６号',
    'rn': 'test',
    'p': [
      [139.7, 35.69],
    ],
  },
  'geometry': {
    'type': 'LineString',
    'coordinates': [
      [139.7, 35.69],
      [139.71, 35.7],
    ],
  },
};
final _record = <String, dynamic>{
  'kisei_naiyo_cd': '01',
  'kisei_meisho': '通行止',
  'rosen_name': '国道16号',
  'tukokisei_info_id': 'test',
  'iconData': {
    'point': ['139.7', '35.69'],
  },
};
Map<String, dynamic> _office(List<dynamic> areas) => {
  'reportDatetime': '2026-07-17T09:00:00+09:00',
  'areaTypes': [
    {'areas': areas},
  ],
};
final _alert = {'warningCode': '3', 'areaCode': '1042600'};
http.Response _json(Object body) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), 200);

void main() {
  for (final sourceName in ['JARTIC', 'MLIT']) {
    test(
      '$sourceName rejects records individually and falls back only when all fail',
      () async {
        final jartic = sourceName == 'JARTIC';
        final good = jartic ? _feature : _record;
        final bad = jartic
            ? {
                'properties': {..._feature['properties'] as Map, 'r': 7},
              }
            : {..._record, 'rosen_name': 7};
        var records = <dynamic>[bad, good, null];
        var status = 200;
        var discoveryDown = false;
        final client = MockClient((request) async {
          final path = request.url.path;
          if (path.endsWith('/target.json')) {
            return discoveryDown ? http.Response('', 503) : _json(_target());
          }
          if (path.contains('pcTukokisei_')) {
            return http.Response(_backup(), discoveryDown ? 503 : 200);
          }
          if (path.endsWith('/R13.json') ||
              path.endsWith('/TukoKisei/83.json')) {
            if (status != 200) return http.Response('missing', status);
            return _json(jartic ? {'features': records} : {'13_東京都': records});
          }
          return http.Response('', 404);
        });
        final fetch = jartic
            ? JarticSource(client).fetch
            : MlitSource(client).fetch;
        final mixed = await fetch(_japan);
        expect(mixed.problems, isEmpty);
        expect(mixed.closures, hasLength(1));
        expect(mixed.closures.single.roadName, contains('国道'));

        records = [bad, null, {}];
        final broken = await fetch(_japan);
        expect(broken.closures.single.id, mixed.closures.single.id);
        expect(
          broken.problems.single,
          contains('showing the last data received'),
        );

        discoveryDown = true;
        final indexFailure = await fetch(_japan);
        expect(indexFailure.closures.single.id, mixed.closures.single.id);
        expect(
          indexFailure.problems.single,
          contains('showing the last data received'),
        );
        discoveryDown = false;

        // A valid non-closure is filtered, not counted as a rejected record.
        records = [
          jartic
              ? {
                  'properties': {'cs': '02', 'rd': '片側交互通行'},
                }
              : {'kisei_naiyo_cd': '02', 'kisei_meisho': '片側交互通行'},
        ];
        final quiet = await fetch(_japan);
        expect(quiet.closures, isEmpty);
        expect(quiet.problems, isEmpty);

        records = [good];
        await fetch(_japan);
        status = 404;
        final missing = await fetch(_japan);
        expect(missing.closures, isEmpty);
        expect(missing.problems, isEmpty);
        status = 503;
        final afterMissing = await fetch(_japan);
        expect(
          afterMissing.closures,
          isEmpty,
          reason: '404 replaced the old closure',
        );
        expect(afterMissing.problems, isNotEmpty);
        status = 200;
        records = [];
        expect((await fetch(_japan)).problems, isEmpty);
      },
    );

    test(
      '$sourceName limits actual file transfers to four across refreshes',
      () {
        fakeAsync((clock) {
          var active = 0;
          var peak = 0;
          var completed = 0;
          final waiting = <(Completer<http.Response>, http.Response)>[];
          final client = MockClient((request) {
            final path = request.url.path;
            if (path.endsWith('/target.json')) {
              return Future.value(_json(_target()));
            }
            active++;
            if (active > peak) peak = active;
            final pending = Completer<http.Response>();
            waiting.add((
              pending,
              path.contains('pcTukokisei_')
                  ? http.Response(_backup(), 200)
                  : http.Response('', 404),
            ));
            return pending.future.whenComplete(() => active--);
          });
          final fetch = sourceName == 'JARTIC'
              ? JarticSource(client).fetch
              : MlitSource(client).fetch;
          for (var i = 0; i < 2; i++) {
            fetch(_japan).then((result) {
              expect(result.problems, isEmpty);
              completed++;
            });
          }
          clock.flushMicrotasks();
          expect(active, 4);
          var batches = 0;
          while (waiting.isNotEmpty) {
            final batch = waiting.toList();
            waiting.clear();
            for (final (pending, response) in batch) {
              pending.complete(response);
            }
            clock.flushMicrotasks();
            batches++;
            expect(batches, lessThan(100));
          }
          expect(batches, greaterThan(1));
          expect(completed, 2);
          expect(peak, 4);
          expect(clock.nonPeriodicTimerCount, 0);
        });
      },
    );
  }

  test('MLIT skips fields that are not record lists, and fails a file with '
      'no lists at all', () async {
    Object body = {'updated': '20260717090000', '13_東京都': <dynamic>[]};
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path.contains('pcTukokisei_')) return http.Response(_backup(), 200);
      if (path.endsWith('/TukoKisei/83.json')) return _json(body);
      return http.Response('', 404);
    });
    final source = MlitSource(client);

    // A metadata field beside an empty list: a quiet file, not a broken one.
    final quiet = await source.fetch(_japan);
    expect(quiet.closures, isEmpty);
    expect(quiet.problems, isEmpty);

    body = {'updated': '20260717090000', 'count': 0};
    final drifted = await source.fetch(_japan);
    expect(drifted.problems, isNotEmpty);
  });

  test(
    'landslide guards each office and municipality, preserving last good data',
    () async {
      var offices = <dynamic>[
        {
          ..._office([_alert]),
          'reportDatetime': 99,
        },
        _office([
          null,
          {'warningCode': 3, 'areaCode': '1042600'},
          _alert,
        ]),
      ];
      final source = LandslideSource(MockClient((_) async => _json(offices)));
      final first = await source.fetch(_japan);
      expect(first.problems, isEmpty);
      expect(first.closures.single.id, 'dosha-10426');

      offices = [
        null,
        {},
        {
          ..._office([_alert]),
          'reportDatetime': 99,
        },
        _office([
          {'warningCode': 3},
        ]),
      ];
      final broken = await source.fetch(_japan);
      expect(broken.closures.single.id, 'dosha-10426');
      expect(
        broken.problems.single,
        contains('JMA landslide: map: all 4 records rejected'),
      );
      expect(
        broken.problems.single,
        contains('showing the last data received'),
      );

      // Unknown municipalities and cleared warnings are legitimate empty data.
      offices = [
        _office([
          {'warningCode': '0', 'areaCode': '1042600'},
          {'warningCode': '3', 'areaCode': '9999900'},
        ]),
      ];
      final quiet = await source.fetch(_japan);
      expect(quiet.closures, isEmpty);
      expect(quiet.problems, isEmpty);
      offices = [];
      expect((await source.fetch(_japan)).problems, isEmpty);
    },
  );

  for (final sourceName in ['JARTIC', 'landslide']) {
    test(
      '$sourceName large and small payloads produce the same sendable closures',
      () async {
        var large = false;
        var broken = false;
        final client = MockClient((request) async {
          if (request.url.path.endsWith('/target.json')) {
            return _json(_target());
          }
          final padding = large ? ' ' * (33 * 1024) : '';
          if (sourceName == 'landslide') {
            return _json([
              {
                ..._office(broken ? [null] : [_alert, _alert]),
                'padding': padding,
              },
            ]);
          }
          if (request.url.path.endsWith('/R13.json')) {
            return _json({
              'features': broken ? [null] : [_feature],
              'padding': padding,
            });
          }
          return http.Response('', 404);
        });
        Future<FeedResult> Function(SearchArea) fetch = sourceName == 'JARTIC'
            ? JarticSource(client).fetch
            : LandslideSource(client).fetch;
        final small = await fetch(_japan);
        large = true;
        final big = await fetch(_japan);
        expect(big.problems, isEmpty);
        expect(big.closures, hasLength(1));
        final a = small.closures.single, b = big.closures.single;
        expect(b.id, a.id);
        expect(b.point, a.point);
        expect(b.roadName, a.roadName);
        expect(b.lines, a.lines);
        expect(b.sourceUrl, a.sourceUrl);
        expect(b.isFullClosure, a.isFullClosure);
        broken = true;
        final fallback = await fetch(_japan);
        expect(
          fallback.problems.single,
          contains('showing the last data received'),
        );
        expect(fallback.closures.single.id, a.id);
      },
    );
  }
}
