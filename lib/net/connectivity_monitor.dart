import 'dart:async';

import 'package:flutter/foundation.dart';

import 'net_error.dart';

/// The screen's offline heuristic, extracted so that it can be unit-tested.
/// It answers three questions: when is the map 'offline', when do the tile
/// layers get re-keyed, and when is the banner allowed to show at all.
///
/// Offline means that enough tile fetches failed at the *network* level, close
/// enough together. The burst threshold keeps a lone blip, one flaky tile on a
/// big zoom-out, from declaring the whole map offline. The linger window lets
/// the state age out on its own once errors stop arriving.
///
/// The tile epoch lives here because bumping it is the retry mechanism for
/// both recovery paths: the rider's explicit retry, and the automatic heal
/// when a radar index fetch succeeds after an outage. flutter_map never
/// retries a failed tile by itself, and re-keying the layers is what refetches
/// the holes.
class ConnectivityMonitor extends ChangeNotifier {
  ConnectivityMonitor({
    DateTime Function()? now,
    this.linger = const Duration(seconds: 12),
    this.threshold = 3,
    Duration startupGrace = const Duration(seconds: 6),
  }) : _now = now ?? DateTime.now {
    // Cold-start grace. Hold the connectivity banners for the first few
    // seconds, so that a momentary gap at launch, with the radio still
    // attaching, does not flash a scary 'No connection' before the first
    // retry has landed.
    _graceTimer = Timer(startupGrace, () {
      _pastStartupGrace = true;
      notifyListeners();
    });
  }

  final DateTime Function() _now;

  /// How long 'offline' persists after the last network-level tile failure.
  final Duration linger;

  /// Socket failures within [linger] needed before declaring offline.
  final int threshold;

  final _recentNetErrors = <DateTime>[];
  DateTime? _lastNetError;
  Timer? _hideTimer;
  Timer? _graceTimer;
  bool _pastStartupGrace = false;
  bool _offlineDismissed = false;
  int _tileEpoch = 0;

  bool get isOffline =>
      _lastNetError != null && _now().difference(_lastNetError!) < linger;

  /// The rider closed the offline banner. A fresh outage brings it back.
  bool get offlineDismissed => _offlineDismissed;

  bool get pastStartupGrace => _pastStartupGrace;

  /// Re-key value for every tile layer. Bumping it drops their caches and
  /// refetches everything visible.
  int get tileEpoch => _tileEpoch;

  /// A tile failed. Non-network errors, such as 404s and server errors, are
  /// ignored here. They are the tile-status monitor's business, not
  /// connectivity's.
  void recordTileError(Object error) {
    final raw = '$error';
    // Deadline timeouts are congestion, not lost connectivity. A saturated
    // per-host queue times tiles out while other requests on the same host
    // succeed, and a real outage surfaces as SocketExceptions anyway.
    // Counting them armed heal(), whose re-key then cancelled the very queue
    // that was slowly draining. That was a self-sustaining refetch storm.
    if (raw.contains('TimeoutException')) return;
    if (!looksLikeConnectivityError(raw)) return;
    final now = _now();
    _recentNetErrors
      ..add(now)
      ..removeWhere((t) => now.difference(t) > linger);
    if (_recentNetErrors.length < threshold) return;

    final alreadyShowing = isOffline;
    _lastNetError = now;
    // Age the banner out on its own if no further errors arrive.
    _hideTimer?.cancel();
    _hideTimer = Timer(linger + const Duration(seconds: 1), notifyListeners);
    // Errors arrive in bursts, one per tile, so notify only on the flip. A
    // new outage re-shows the banner even if the last one was dismissed.
    if (!alreadyShowing) {
      _offlineDismissed = false;
      notifyListeners();
    }
  }

  /// Something upstream succeeded, namely the radar index fetch, so
  /// connectivity is back. If tiles errored during the outage, this re-keys
  /// the layers so the holes refetch. It returns whether there *was* an
  /// outage, so the caller can reset its per-tile bookkeeping alongside.
  bool heal() {
    if (_lastNetError == null) return false;
    _lastNetError = null;
    _recentNetErrors.clear();
    _hideTimer?.cancel();
    _tileEpoch++;
    notifyListeners();
    return true;
  }

  /// Explicit retry, from a banner tap or the refresh button: re-key every
  /// tile layer.
  void bumpEpoch() {
    _tileEpoch++;
    notifyListeners();
  }

  void dismissOffline() {
    _offlineDismissed = true;
    notifyListeners();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _graceTimer?.cancel();
    super.dispose();
  }
}
