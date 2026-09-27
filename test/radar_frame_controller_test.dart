import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rindo/jma/jma_api.dart';
import 'package:rindo/screens/radar_map/radar_frame_controller.dart';

/// Pins the load/replace/heal callback contract, playback (last-frame
/// dwell), the error linger, and the reconnect backoff - all previously
/// buried in the screen's State and untestable.

List<JmaFrame> _frames(String basetime) => [
  JmaFrame(basetime: basetime, validtime: '${basetime}05', offsetMin: 0),
  JmaFrame(basetime: basetime, validtime: '${basetime}20', offsetMin: 15),
  JmaFrame(basetime: basetime, validtime: '${basetime}35', offsetMin: 30),
];

void main() {
  late int loaded, replaced, reconnected;
  late Future<List<JmaFrame>> Function() loader;

  RadarFrameController build() => RadarFrameController(
    loadFrames: () => loader(),
    onLoaded: () => loaded++,
    onFramesReplaced: () => replaced++,
    onReconnect: () => reconnected++,
  );

  setUp(() {
    loaded = 0;
    replaced = 0;
    reconnected = 0;
    loader = () async => _frames('A');
  });

  test('first load populates frames and counts as a replacement', () async {
    final c = build();
    await c.load();
    expect(c.frames, hasLength(3));
    expect(c.radarError, isNull);
    expect(loaded, 1);
    expect(replaced, 1); // nothing -> something is a new frame set
    c.dispose();
  });

  test('a refresh of the same frame set is not a replacement', () async {
    final c = build();
    await c.load();
    await c.load();
    expect(loaded, 2);
    expect(replaced, 1);

    // New basetime -> new layers -> the screen must reset tile bookkeeping.
    loader = () async => _frames('B');
    await c.load();
    expect(replaced, 2);
    c.dispose();
  });

  test('playback wraps with a dwell on the final frame', () async {
    final c = build();
    await c.load();
    expect(c.frameIndex, 0);
    c.tick();
    expect(c.frameIndex, 1);
    c.tick();
    expect(c.frameIndex, 2);
    c.tick(); // dwell: hold the +60 min frame one extra tick
    expect(c.frameIndex, 2);
    c.tick();
    expect(c.frameIndex, 0);
    c.dispose();
  });

  test('seek pauses playback; togglePlay resumes it', () async {
    final c = build();
    await c.load();
    c.seek(1);
    expect(c.frameIndex, 1);
    expect(c.playing, isFalse);
    c.tick();
    expect(c.frameIndex, 1); // paused: ticks are ignored
    c.togglePlay();
    c.tick();
    expect(c.frameIndex, 2);
    c.dispose();
  });

  test('a failed refresh with stale frames on screen stays quiet', () async {
    final c = build();
    await c.load();
    loader = () async => throw Exception('boom');
    await c.load();
    expect(c.radarError, isNull); // stale frames beat an error banner
    expect(c.frames, hasLength(3));
    c.dispose();
  });

  test('with nothing on screen the error shows, lingers out, and backoff '
      'retries until a load succeeds', () {
    fakeAsync((fa) {
      var calls = 0;
      loader = () {
        calls++;
        return Future.error(Exception('down'));
      };
      // Linger shortened below the first 3 s backoff so the age-out is
      // observable before a failed retry re-raises the error.
      final c = RadarFrameController(
        loadFrames: () => loader(),
        onLoaded: () => loaded++,
        onFramesReplaced: () => replaced++,
        onReconnect: () => reconnected++,
        errorLinger: const Duration(seconds: 2),
      );
      c.load();
      fa.flushMicrotasks();
      expect(c.radarError, contains('down'));
      expect(c.reconnectAttempt, 1);

      // The error banner ages out on its own...
      fa.elapse(const Duration(seconds: 2));
      expect(c.radarError, isNull);

      // ...until the 3 s backoff retry fails again (still nothing on
      // screen), re-raising it and refreshing closures alongside.
      fa.elapse(const Duration(seconds: 1));
      expect(calls, 2);
      expect(reconnected, 1);
      expect(c.radarError, contains('down'));
      fa.elapse(const Duration(seconds: 6));
      expect(calls, 3);

      // Signal returns: the next retry (12 s) succeeds and the loop stops.
      loader = () async => _frames('A');
      fa.elapse(const Duration(seconds: 12));
      expect(c.frames, hasLength(3));
      expect(c.radarError, isNull);
      expect(c.reconnectAttempt, 0);
      final callsAtRecovery = calls;
      fa.elapse(const Duration(minutes: 2));
      expect(calls, callsAtRecovery); // no timers left running
      c.dispose();
    });
  });

  test('seek clamps to the frame set and ignores an empty one', () async {
    final c = build();
    c.seek(2); // no frames yet
    expect(c.frameIndex, 0);
    await c.load();
    c.seek(99);
    expect(c.frameIndex, 2);
    expect(c.playing, isFalse);
    c.dispose();
  });

  test('loads asked for while one is in flight share it', () async {
    var calls = 0;
    final gate = Completer<void>();
    loader = () async {
      calls++;
      await gate.future;
      return _frames('A');
    };
    final c = build();
    final a = c.load();
    final b = c.load();
    gate.complete();
    await Future.wait([a, b]);
    expect(calls, 1);
    expect(loaded, 1);
    c.dispose();
  });

  test('suspend stops playback and the backoff; resume reloads', () {
    fakeAsync((async) {
      final c = build();
      c.start();
      async.flushMicrotasks();
      final loadsBefore = loaded;
      c.suspend();
      final index = c.frameIndex;
      async.elapse(const Duration(minutes: 10));
      expect(c.frameIndex, index, reason: 'no playback in the background');
      expect(loaded, loadsBefore, reason: 'no refresh in the background');

      c.resume();
      async.flushMicrotasks();
      expect(loaded, loadsBefore + 1);
      async.elapse(c.frameTick * 2);
      expect(c.frameIndex, isNot(index), reason: 'playback restarted');
      c.dispose();
    });
  });

  test('a load that fails while suspended schedules no reconnect', () {
    fakeAsync((async) {
      loader = () async => throw Exception('offline');
      final c = build();
      c.suspend();
      c.load();
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 1));
      expect(reconnected, 0);
      c.dispose();
    });
  });
}
