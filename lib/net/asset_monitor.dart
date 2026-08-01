import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart';

import 'response_copy.dart';

/// What a request is fetching, so the debug sheet can group meaningfully.
enum AssetKind { baseTile, radarTile, radarIndex, closures, forecast, other }

String assetKindLabel(AssetKind kind) => switch (kind) {
  AssetKind.baseTile => 'Base map tiles',
  AssetKind.radarTile => 'Radar tiles',
  AssetKind.radarIndex => 'Radar index (targetTimes)',
  AssetKind.closures => 'Closures feeds',
  AssetKind.forecast => 'Weather forecast',
  AssetKind.other => 'Other',
};

/// URL → kind, keyed off the hosts and paths in radar_map_view.dart,
/// jma_api.dart, and the feed clients under closures/ and hazards/.
AssetKind classifyAsset(Uri url) {
  final host = url.host;
  final path = url.path;
  if (host.contains('cyclosm') || path.contains('World_Street_Map')) {
    return AssetKind.baseTile;
  }
  if (path.contains('/hrpns/')) return AssetKind.radarTile;
  if (path.contains('targetTimes')) return AssetKind.radarIndex;
  // Both the structured series and the prose overview live under here.
  if (path.contains('/forecast/data/')) return AssetKind.forecast;
  if (host == 'www.jartic.or.jp' ||
      host.endsWith('mlit.go.jp') ||
      path.contains('/warning/data/landslide')) {
    return AssetKind.closures;
  }
  return AssetKind.other;
}

/// Tile zoom for tile-shaped URLs. All three templates put z third-from-last
/// (cyclosm `{z}/{x}/{y}.png`, esri `{z}/{y}/{x}`, hrpns `{z}/{x}/{y}.png`).
int? _tileZoom(Uri url, AssetKind kind) {
  if (kind != AssetKind.baseTile && kind != AssetKind.radarTile) return null;
  final segs = url.pathSegments;
  if (segs.length < 3) return null;
  return int.tryParse(segs[segs.length - 3]);
}

/// The radar frame that a tile belongs to: the validtime segment of
/// `.../{basetime}/none/{validtime}/surf/hrpns/{z}/{x}/{y}.png`.
String? _frameTime(Uri url, AssetKind kind) {
  if (kind != AssetKind.radarTile) return null;
  final segs = url.pathSegments;
  final i = segs.indexOf('hrpns');
  return i >= 2 ? segs[i - 2] : null;
}

/// Aggregate load state of one radar frame's tiles at one zoom, shown as the
/// per-frame dots in the frame strip.
enum FrameLoadState { pending, loading, loaded, failed }

/// One request's story: what was asked for and how it ended. [AssetMonitor]
/// mutates it in place as the request progresses. [endedAt] == null ⇒ in
/// flight.
class AssetRequest {
  AssetRequest._(
    this.id,
    this.url,
    this.startedAt,
    this.kind,
    this.z,
    this.frameTime,
  );

  final int id;
  final Uri url;
  final DateTime startedAt;
  final AssetKind kind;
  final int? z;

  /// Radar tiles only: the validtime of the frame this tile belongs to.
  final String? frameTime;

  DateTime? endedAt;
  int? statusCode;
  int bytes = 0;
  String? error;
  bool cancelled = false;

  bool get inFlight => endedAt == null;
  bool get ok =>
      !cancelled &&
      error == null &&
      statusCode != null &&
      statusCode! ~/ 100 == 2;

  /// Compact display name: `base 6/56/25`, `radar 8/227/100 @0405`, or the
  /// host and last segment for the JSON and XML feeds.
  String get shortName {
    final segs = url.pathSegments;
    switch (kind) {
      case AssetKind.baseTile:
        return 'base ${_zxy(segs)}';
      case AssetKind.radarTile:
        final valid = frameTime ?? '';
        final hhmm = valid.length >= 12 ? ' @${valid.substring(8, 12)}' : '';
        return 'radar ${_zxy(segs)}$hhmm';
      case AssetKind.radarIndex:
        return segs.isEmpty ? url.host : segs.last;
      case AssetKind.forecast:
        // .../forecast/{office}.json and .../overview_forecast/{office}.json
        // share a last segment, so keep the directory that tells them apart.
        return segs.length < 2
            ? url.host
            : '${segs[segs.length - 2]}/${segs.last}';
      case AssetKind.closures:
      case AssetKind.other:
        return '${url.host}/${segs.isEmpty ? '' : segs.last}';
    }
  }

  static String _zxy(List<String> segs) {
    if (segs.length < 3) return '?';
    final y = segs.last.split('.').first;
    return '${segs[segs.length - 3]}/${segs[segs.length - 2]}/$y';
  }
}

/// Outcome counters for one bucket (a kind overall, or one zoom of it).
class AssetTally {
  int ok = 0, notFound = 0, httpError = 0, failed = 0, cancelled = 0;
  int okBytes = 0;

  int get total => ok + notFound + httpError + failed + cancelled;

  void _add(AssetRequest r) {
    if (r.cancelled) {
      cancelled++;
    } else if (r.error != null) {
      failed++;
    } else if (r.statusCode == 404) {
      notFound++;
    } else if (r.ok) {
      ok++;
      okBytes += r.bytes;
    } else {
      httpError++;
    }
  }

  void _reset() {
    ok = notFound = httpError = failed = cancelled = 0;
    okBytes = 0;
  }
}

class KindStats {
  final AssetTally all = AssetTally();
  final SplayTreeMap<int, AssetTally> byZoom = SplayTreeMap<int, AssetTally>();
  String? lastError;
  DateTime? lastErrorAt;

  void _reset() {
    all._reset();
    byZoom.clear();
    lastError = null;
    lastErrorAt = null;
  }
}

/// Records the lifecycle of every HTTP request the app makes (via
/// [MonitoredClient]) so the debug sheet can show what is in flight, what
/// failed, and why. The cumulative tallies survive the bounded recent log.
class AssetMonitor extends ChangeNotifier {
  static const _recentLimit = 150;

  int _nextId = 0;
  final Map<int, AssetRequest> _active = {};
  final ListQueue<AssetRequest> _recent = ListQueue();
  final Map<AssetKind, KindStats> stats = {
    for (final k in AssetKind.values) k: KindStats(),
  };
  DateTime countingSince = DateTime.now();

  /// Per-frame radar tile outcomes, keyed (validtime, zoom). Zoom is part of
  /// the key so that tiles fetched at a previous native level cannot
  /// masquerade as the current level being loaded. This is functional UI state
  /// behind the frame strip's dots, so [resetCounters], a debug affordance,
  /// leaves it alone. [resetRadarFrames] clears it when the layers re-key.
  final Map<(String, int), AssetTally> radarFrames = {};

  // Tile loads arrive in bursts of dozens, so coalesce the notifications. An
  // open debug sheet then repaints a few times a second, not once per tile.
  Timer? _notifyTimer;

  /// Requests still on the wire, oldest first.
  List<AssetRequest> get inFlight =>
      _active.values.toList()
        ..sort((a, b) => a.startedAt.compareTo(b.startedAt));

  /// Completed requests, oldest → newest, bounded to the last [_recentLimit].
  List<AssetRequest> get recent => List.unmodifiable(_recent);

  AssetRequest begin(Uri url) {
    final kind = classifyAsset(url);
    final r = AssetRequest._(
      _nextId++,
      url,
      DateTime.now(),
      kind,
      _tileZoom(url, kind),
      _frameTime(url, kind),
    );
    _active[r.id] = r;
    _bump();
    return r;
  }

  /// [FrameLoadState.loaded] means every finished tile came back clean. A 404
  /// is JMA for 'no rain here', so it counts as clean. [FrameLoadState.failed]
  /// means at least one real failure. Cancellations alone stay [pending],
  /// because the map simply stopped needing those tiles.
  FrameLoadState frameState(String validtime, int z) {
    final loading = _active.values.any(
      (r) =>
          r.kind == AssetKind.radarTile && r.frameTime == validtime && r.z == z,
    );
    if (loading) return FrameLoadState.loading;
    final t = radarFrames[(validtime, z)];
    if (t == null) return FrameLoadState.pending;
    if (t.failed + t.httpError > 0) return FrameLoadState.failed;
    if (t.ok + t.notFound > 0) return FrameLoadState.loaded;
    return FrameLoadState.pending;
  }

  /// Forget the per-frame outcomes. Call this when the radar layers re-key, on
  /// a retry, on connectivity healing, or on a replaced frame set. The dots
  /// then go back to pending until the refetch answers.
  void resetRadarFrames() {
    radarFrames.clear();
    _bump();
  }

  void headersReceived(AssetRequest r, int statusCode) {
    r.statusCode = statusCode;
    _bump();
  }

  void done(AssetRequest r) => _finish(r);

  void fail(AssetRequest r, Object error) {
    if (r.endedAt != null) return;
    // flutter_map aborts requests for tiles the map stopped needing (pruned
    // on pan or zoom). That is a cancellation, not a failure. Counting it as
    // failed floods the tallies and wrongly flips frame dots red during zoom
    // churn.
    if (error is RequestAbortedException) {
      cancel(r);
      return;
    }
    r.error = '$error';
    _finish(r);
  }

  void cancel(AssetRequest r) {
    if (r.endedAt != null) return;
    r.cancelled = true;
    _finish(r);
  }

  void _finish(AssetRequest r) {
    if (r.endedAt != null) return;
    r.endedAt = DateTime.now();
    _active.remove(r.id);
    _recent.addLast(r);
    while (_recent.length > _recentLimit) {
      _recent.removeFirst();
    }
    final s = stats[r.kind]!;
    s.all._add(r);
    final z = r.z;
    if (z != null) (s.byZoom[z] ??= AssetTally())._add(r);
    final ft = r.frameTime;
    if (ft != null && z != null) {
      (radarFrames[(ft, z)] ??= AssetTally())._add(r);
    }
    if (r.error != null) {
      s.lastError = r.error;
      s.lastErrorAt = r.endedAt;
    }
    _bump();
  }

  /// Zero the tallies and the log. In-flight requests keep tracking.
  void resetCounters() {
    for (final s in stats.values) {
      s._reset();
    }
    _recent.clear();
    countingSince = DateTime.now();
    notifyListeners();
  }

  void _bump() {
    if (_notifyTimer != null) return;
    _notifyTimer = Timer(const Duration(milliseconds: 200), () {
      _notifyTimer = null;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    super.dispose();
  }
}

/// Wraps any [Client] and reports every request to an [AssetMonitor]. Wrap the
/// *outermost* client, outside the retries, so that one logical fetch makes
/// one record. The byte counts are what actually arrived. If a listener
/// cancels the body stream mid-read, the request is recorded as cancelled, not
/// failed.
class MonitoredClient extends BaseClient {
  MonitoredClient(this._inner, this._monitor);

  final Client _inner;
  final AssetMonitor _monitor;

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    final rec = _monitor.begin(request.url);
    final StreamedResponse res;
    try {
      res = await _inner.send(request);
    } catch (e) {
      _monitor.fail(rec, e);
      rethrow;
    }
    _monitor.headersReceived(rec, res.statusCode);
    return res.copyWithStream(_tap(res.stream, rec));
  }

  Stream<List<int>> _tap(Stream<List<int>> body, AssetRequest rec) {
    final out = StreamController<List<int>>(sync: true);
    late StreamSubscription<List<int>> sub;
    out.onListen = () {
      sub = body.listen(
        (chunk) {
          rec.bytes += chunk.length;
          out.add(chunk);
        },
        onError: (Object e, StackTrace st) {
          _monitor.fail(rec, e);
          out.addError(e, st);
        },
        onDone: () {
          _monitor.done(rec);
          out.close();
        },
      );
      out.onPause = sub.pause;
      out.onResume = sub.resume;
      out.onCancel = () {
        _monitor.cancel(rec);
        return sub.cancel();
      };
    };
    return out.stream;
  }

  @override
  void close() => _inner.close();
}
