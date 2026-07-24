import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rindo/net/connectivity_monitor.dart';

/// The offline heuristic used to live untested inside the screen; these pin
/// the burst threshold, the linger aging, dismissal, and the heal path.

class _Clock {
  DateTime now = DateTime(2026, 7, 21, 12);
  void advance(Duration d) => now = now.add(d);
}

const _sockErr =
    'ClientException with SocketException: No route to host '
    '(OS Error: No route to host, errno = 113)';

void main() {
  late _Clock clock;
  late ConnectivityMonitor m;
  late int notifications;

  setUp(() {
    clock = _Clock();
    m = ConnectivityMonitor(now: () => clock.now);
    notifications = 0;
    m.addListener(() => notifications++);
  });

  tearDown(() => m.dispose());

  test('a couple of blips never flip offline', () {
    m.recordTileError(_sockErr);
    m.recordTileError(_sockErr);
    expect(m.isOffline, isFalse);
    expect(notifications, 0);
  });

  test(
    'a burst flips offline exactly once; non-network errors never count',
    () {
      // 404s and server errors are the tile-status monitor's business.
      for (var i = 0; i < 10; i++) {
        m.recordTileError('HTTP request failed, statusCode: 404');
      }
      expect(m.isOffline, isFalse);

      m.recordTileError(_sockErr);
      m.recordTileError(_sockErr);
      m.recordTileError(_sockErr);
      expect(m.isOffline, isTrue);
      expect(notifications, 1); // the flip, not one per error
      m.recordTileError(_sockErr);
      expect(notifications, 1);
    },
  );

  test('deadline timeouts are congestion, not an outage: never flip offline '
      'or arm heal', () {
    // A saturated per-host queue times tiles out while the same host keeps
    // answering other requests; treating that as an outage made heal()
    // cancel the draining queue - a self-sustaining refetch storm.
    for (var i = 0; i < 10; i++) {
      m.recordTileError(
        'TimeoutException after 0:00:20.000000: Future not completed',
      );
    }
    expect(m.isOffline, isFalse);
    expect(m.heal(), isFalse); // nothing armed -> no epoch churn
    expect(m.tileEpoch, 0);
    expect(notifications, 0);
  });

  test('offline ages out on its own after the linger', () {
    for (var i = 0; i < 3; i++) {
      m.recordTileError(_sockErr);
    }
    expect(m.isOffline, isTrue);
    clock.advance(m.linger + const Duration(seconds: 1));
    expect(m.isOffline, isFalse);
  });

  test('heal clears the outage, re-keys the tiles, and reports it', () {
    expect(m.heal(), isFalse); // no outage: nothing to do, no epoch churn
    expect(m.tileEpoch, 0);

    for (var i = 0; i < 3; i++) {
      m.recordTileError(_sockErr);
    }
    expect(m.heal(), isTrue);
    expect(m.isOffline, isFalse);
    expect(m.tileEpoch, 1);
    expect(m.heal(), isFalse); // already healed
    expect(m.tileEpoch, 1);
  });

  test('a fresh outage un-dismisses the offline banner', () {
    for (var i = 0; i < 3; i++) {
      m.recordTileError(_sockErr);
    }
    m.dismissOffline();
    expect(m.offlineDismissed, isTrue);

    // The outage ages out, then a new burst arrives: the banner must
    // re-show even though the last one was dismissed.
    clock.advance(m.linger * 2);
    for (var i = 0; i < 3; i++) {
      m.recordTileError(_sockErr);
    }
    expect(m.isOffline, isTrue);
    expect(m.offlineDismissed, isFalse);
  });

  test('bumpEpoch re-keys and notifies (the explicit retry path)', () {
    m.bumpEpoch();
    expect(m.tileEpoch, 1);
    expect(notifications, 1);
  });

  test('startup grace holds the banners, then lifts', () {
    fakeAsync((fa) {
      final graced = ConnectivityMonitor(
        now: () => clock.now,
        startupGrace: const Duration(seconds: 6),
      );
      expect(graced.pastStartupGrace, isFalse);
      fa.elapse(const Duration(seconds: 7));
      expect(graced.pastStartupGrace, isTrue);
      graced.dispose();
    });
  });
}
