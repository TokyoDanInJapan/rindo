import 'road_closure.dart';

/// What one closure source returned for a search: the closures, plus one line
/// for each part of the feed that could not be fetched.
///
/// A part that failed falls back to what the source last fetched for it, see
/// [LastGood]. The closures a rider has already seen then survive a dead zone,
/// and the problem line says the data is older.
class FeedResult {
  const FeedResult(this.closures, [this.problems = const []]);

  final List<RoadClosure> closures;
  final List<String> problems;
}

/// The last successful parse of each part of a feed: a JARTIC prefecture
/// tile, an MLIT bureau file or the landslide map. It is kept unfiltered, so a
/// fallback serves whatever search area is asked about next.
///
/// Entries expire after [maxAge]. A closure from hours ago is still worth
/// showing while the feed is unreachable, because a stale closure is the safe
/// way to be wrong. But one from the morning is not.
class LastGood<K> {
  LastGood({this.maxAge = const Duration(hours: 3), DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Duration maxAge;
  final DateTime Function() _now;
  final _entries = <K, (DateTime, List<RoadClosure>)>{};

  void put(K key, List<RoadClosure> closures) =>
      _entries[key] = (_now(), closures);

  /// The last good closures for [key], or null if there are none young enough.
  List<RoadClosure>? get(K key) {
    final entry = _entries[key];
    if (entry == null) return null;
    final (at, closures) = entry;
    return _now().difference(at) <= maxAge ? closures : null;
  }
}

/// The problem line for a feed whose parts partly failed: how many, and
/// whether the older data is standing in for them.
String partsProblem({
  required int failed,
  required int total,
  required String unit,
  required bool fellBack,
  Object? cause,
}) {
  final what = failed == total ? 'all $total $unit' : '$failed of $total $unit';
  final because = cause == null ? '' : ' ($cause)';
  final instead = fellBack ? ', showing the last data received' : '';
  return '$what unavailable$because$instead';
}
