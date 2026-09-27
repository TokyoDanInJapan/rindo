import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../jma/jma_api.dart';

/// Radar frame state extracted from the screen: the frame list and its refresh
/// cycle, the playback with its last-frame dwell, the linger on the radar
/// error, and the fast-reconnect backoff after a failed load.
///
/// It takes a plain loader function, and the screen passes `JmaApi.getFrames`.
/// Tests can therefore drive it with a stub and a pumped clock, with no HTTP
/// mocking.
class RadarFrameController extends ChangeNotifier {
  RadarFrameController({
    required Future<List<JmaFrame>> Function() loadFrames,
    required this.onLoaded,
    required this.onFramesReplaced,
    this.onReconnect,
    this.frameTick = const Duration(milliseconds: 750),
    this.refreshEvery = const Duration(minutes: 5),
    this.errorLinger = const Duration(seconds: 8),
  }) : _loader = loadFrames;

  final Future<List<JmaFrame>> Function() _loader;

  /// A load succeeded, so connectivity is provably back. The screen heals the
  /// ConnectivityMonitor, which re-keys the tiles if there was an outage.
  final VoidCallback onLoaded;

  /// The frame *set* changed, so the radar layers are about to be rebuilt. The
  /// screen resets its per-tile bookkeeping. Stale failure entries would
  /// otherwise keep the failed-tiles banner up forever.
  final VoidCallback onFramesReplaced;

  /// A backoff retry fired, and the screen refreshes the closures alongside.
  final VoidCallback? onReconnect;

  final Duration frameTick;
  final Duration refreshEvery;

  /// A transient radar error banner auto-hides after this.
  final Duration errorLinger;

  /// Retry delays after consecutive failed loads, so that the radar recovers
  /// within seconds of the signal returning. It does not wait for the 5-minute
  /// refresh.
  static const reconnectBackoff = [3, 6, 12, 24, 30]; // seconds

  List<JmaFrame> _frames = [];
  int _frameIndex = 0;
  bool _playing = true;
  int _lastFrameDwell = 0; // extra ticks spent holding the final frame
  String? _radarError;
  int _reconnectAttempt = 0;
  Timer? _playTimer;
  Timer? _refreshTimer;
  Timer? _errorTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _started = false;
  bool _suspended = false;

  // The load in flight, shared by every caller that asks meanwhile. The
  // refresh timer, the reconnect backoff, an app resume and the refresh
  // button can all ask at once, and two loads finishing out of order could
  // put an older frame set back on screen.
  Future<void>? _loading;

  List<JmaFrame> get frames => _frames;
  int get frameIndex => _frameIndex;
  bool get playing => _playing;
  String? get radarError => _radarError;
  int get reconnectAttempt => _reconnectAttempt;
  JmaFrame? get activeFrame => _frames.isEmpty ? null : _frames[_frameIndex];

  /// Start the first load, and start the playback and refresh timers.
  void start() {
    _started = true;
    unawaited(load());
    _playTimer?.cancel();
    _refreshTimer?.cancel();
    _playTimer = Timer.periodic(frameTick, (_) => tick());
    _refreshTimer = Timer.periodic(refreshEvery, (_) => load());
  }

  /// The app went to the background. Stop playback, the refresh and any
  /// reconnect backoff, so a hidden map spends no battery or data.
  void suspend() {
    _suspended = true;
    _playTimer?.cancel();
    _refreshTimer?.cancel();
    _reconnectTimer?.cancel();
    _playTimer = _refreshTimer = _reconnectTimer = null;
  }

  /// The app is back in front. Restart what [suspend] stopped, with a fresh
  /// load, because the frames have almost certainly moved on.
  void resume() {
    if (!_suspended) {
      unawaited(load());
      return;
    }
    _suspended = false;
    if (_started) {
      start();
    } else {
      unawaited(load());
    }
  }

  /// Fetch the frame set. Callers that ask while a load is in flight share
  /// it, rather than starting another.
  Future<void> load() =>
      _loading ??= _load().whenComplete(() => _loading = null);

  Future<void> _load() async {
    try {
      final frames = await _loader();
      if (_disposed) return;
      final replaced =
          _frames.isEmpty ||
          frames.first.urlTemplate != _frames.first.urlTemplate;
      _frames = frames;
      _frameIndex = _frameIndex.clamp(0, frames.length - 1);
      _radarError = null;
      notifyListeners();
      _errorTimer?.cancel();
      // Loaded cleanly, so stop the fast-reconnect loop.
      _reconnectTimer?.cancel();
      _reconnectAttempt = 0;
      onLoaded();
      if (replaced) onFramesReplaced();
    } catch (e) {
      if (_disposed) return;
      // Keep showing stale frames where there are any. Surface the error only
      // when there is nothing on screen at all.
      _radarError = _frames.isEmpty ? '$e' : null;
      notifyListeners();
      _errorTimer?.cancel();
      if (_radarError != null) {
        _errorTimer = Timer(errorLinger, () {
          if (_disposed) return;
          _radarError = null;
          notifyListeners();
        });
      }
      _scheduleReconnect();
    }
  }

  /// One playback step, driven by the periodic timer in [start]. It is public
  /// so that tests can step playback without waiting on wall-clock ticks.
  void tick() {
    if (!_playing || _frames.length < 2) return;
    // Hold the last frame, at +60 min, for two ticks, so that the loop
    // visibly ends before it wraps back to the past.
    if (_frameIndex == _frames.length - 1 && _lastFrameDwell < 1) {
      _lastFrameDwell++;
      return;
    }
    _lastFrameDwell = 0;
    _frameIndex = (_frameIndex + 1) % _frames.length;
    notifyListeners();
  }

  void togglePlay() {
    _playing = !_playing;
    notifyListeners();
  }

  /// The x on the radar error banner.
  void dismissError() {
    _errorTimer?.cancel();
    _radarError = null;
    notifyListeners();
  }

  /// Scrubber seek. It also pauses playback. An index outside the frame set
  /// is clamped, so a stale scrubber position cannot index past the end.
  void seek(int i) {
    if (_frames.isEmpty) return;
    _playing = false;
    _frameIndex = i.clamp(0, _frames.length - 1);
    notifyListeners();
  }

  void _scheduleReconnect() {
    _reconnectTimer?.cancel();
    // Suspended: the resume loads anyway, so there is nothing to back off.
    if (_suspended) return;
    final secs =
        reconnectBackoff[_reconnectAttempt.clamp(
          0,
          reconnectBackoff.length - 1,
        )];
    _reconnectAttempt++;
    _reconnectTimer = Timer(Duration(seconds: secs), () {
      unawaited(load());
      onReconnect?.call();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _playTimer?.cancel();
    _refreshTimer?.cancel();
    _errorTimer?.cancel();
    _reconnectTimer?.cancel();
    super.dispose();
  }
}
