import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'feed_exception.dart';

typedef FeedError = FeedException Function(String message);

/// Fetch a whole feed under one deadline, including the response body.
/// Completing the abort trigger releases the transport as well as the caller.
/// The timeout still bounds clients which do not implement abortion, such as
/// simple test doubles. Parsing starts after the transfer deadline is cleared.
Future<T> fetchFeed<T>(
  http.Client client,
  Uri url, {
  required Duration deadline,
  required String resource,
  required FeedError error,
  required FutureOr<T> Function(Uint8List bytes) parse,
  T Function()? onNotFound,
}) async {
  final response = await _get(
    client,
    url,
    deadline: deadline,
    resource: resource,
  );
  if (response.statusCode == 404 && onNotFound != null) return onNotFound();
  if (response.statusCode != 200) {
    throw error('$resource ${response.statusCode}');
  }
  return parse(response.bodyBytes);
}

/// A parsed feed file and the validators that its server sent with it, so
/// that the next fetch can ask whether the file has changed. See
/// [fetchFeedIfChanged].
class Validated<T> {
  const Validated(this.value, {this.etag, this.lastModified});

  final T value;
  final String? etag;
  final String? lastModified;
}

/// Fetch [url] like [fetchFeed], but send the validators of [previous]. If
/// the server answers 304 Not Modified, the file has not changed, so this
/// returns [previous] and downloads and parses nothing.
///
/// Use it for a file that is fetched again and again under the same URL. The
/// JMA landslide map, for example, is 144 KB and often unchanged for months.
Future<Validated<T>> fetchFeedIfChanged<T>(
  http.Client client,
  Uri url, {
  required Validated<T>? previous,
  required Duration deadline,
  required String resource,
  required FeedError error,
  required FutureOr<T> Function(Uint8List bytes) parse,
}) async {
  final etag = previous?.etag;
  final lastModified = previous?.lastModified;
  final response = await _get(
    client,
    url,
    deadline: deadline,
    resource: resource,
    headers: {'If-None-Match': ?etag, 'If-Modified-Since': ?lastModified},
  );
  if (response.statusCode == 304 && previous != null) return previous;
  if (response.statusCode != 200) {
    throw error('$resource ${response.statusCode}');
  }
  return Validated(
    await parse(response.bodyBytes),
    etag: response.headers['etag'],
    lastModified: response.headers['last-modified'],
  );
}

/// One GET under [deadline], body included, which aborts the transfer when
/// the deadline passes.
Future<http.Response> _get(
  http.Client client,
  Uri url, {
  required Duration deadline,
  required String resource,
  Map<String, String> headers = const {},
}) {
  final abort = Completer<void>();
  final request = http.AbortableRequest('GET', url, abortTrigger: abort.future)
    ..headers.addAll(headers);
  return (() async {
    final streamed = await client.send(request);
    return http.Response.fromStream(streamed);
  })().timeout(
    deadline,
    onTimeout: () {
      abort.complete();
      throw TimeoutException('$resource transfer', deadline);
    },
  );
}

/// Decode explicitly as UTF-8: feeds often omit the charset and http would
/// otherwise interpret Japanese text as Latin-1. [select] checks a nested
/// value, such as JARTIC's features, using the same labelled shape failure.
T decodeFeedJson<T>(
  Uint8List bytes, {
  required String resource,
  required FeedError error,
  Object? Function(dynamic document)? select,
}) {
  final dynamic document = jsonDecode(utf8.decode(bytes));
  final value = select == null ? document : select(document);
  if (value is! T) throw error('$resource: unexpected shape');
  return value;
}

Future<T> fetchFeedJson<T>(
  http.Client client,
  Uri url, {
  required Duration deadline,
  required String resource,
  required FeedError error,
  Object? Function(dynamic document)? select,
}) => fetchFeed(
  client,
  url,
  deadline: deadline,
  resource: resource,
  error: error,
  parse: (bytes) => decodeFeedJson<T>(
    bytes,
    resource: resource,
    error: error,
    select: select,
  ),
);

/// Keep the worker closure here so it captures only bytes and a pure parser,
/// never a source's HTTP client or last-good cache. RoadClosure and its nested
/// lists, coordinates, URIs and dates are plain, isolate-sendable data.
Future<T> parseFeedBytes<T>(
  Uint8List bytes,
  T Function(Uint8List) parse,
) async {
  if (bytes.length <= 32 * 1024) return parse(bytes);
  return Isolate.run(() => parse(bytes));
}

/// Null means a valid record which is not relevant, such as an open road.
/// A malformed record throws instead. A wholly rejected non-empty payload
/// must not replace last-good data with a misleading empty result.
List<T> parseFeedRecords<T>(
  Iterable<dynamic> records,
  T? Function(dynamic record) parse, {
  required String resource,
  required FeedError error,
}) {
  final out = <T>[];
  var total = 0;
  var rejected = 0;
  for (final record in records) {
    total++;
    try {
      final value = parse(record);
      if (value != null) out.add(value);
    } catch (_) {
      // Anything one record throws, a RangeError from a short string say,
      // rejects that record alone. JARTIC always parsed per feature this
      // way, and a narrower catch would let one odd feature fail its tile.
      rejected++;
    }
  }
  if (total > 0 && rejected == total) {
    throw error('$resource: all $rejected records rejected');
  }
  return out;
}

/// Per-source pool shared across refreshes. Only running work starts a
/// transfer deadline; waiting for a slot must not spend that deadline.
class FeedPool {
  FeedPool({this.limit = 4}) : assert(limit > 0);

  final int limit;
  int _active = 0;
  final _waiting = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() fetch) async {
    if (_active == limit) {
      final ready = Completer<void>();
      _waiting.add(ready);
      await ready.future;
    } else {
      _active++;
    }
    try {
      return await fetch();
    } finally {
      if (_waiting.isEmpty) {
        _active--;
      } else {
        _waiting.removeFirst().complete();
      }
    }
  }
}

/// Parsed copies of feed files whose URL names a snapshot, such as JARTIC's
/// `{target}/d/301/R20.json` or MLIT's `backup/{time}/{id}/TukoKisei/83.json`.
/// A file under one snapshot never changes, so a second request for the same
/// URL can reuse the first answer.
///
/// That saves downloads when a refetch follows soon after the last one: the
/// retry after a partial failure, a dropped or cleared pin, a loaded route,
/// the app coming back to the front, or the refresh button. A new snapshot
/// gives new URLs, so it is always fetched.
///
/// Entries expire after [maxAge] all the same, in case a server ever rewrites
/// a snapshot. The cache keeps at most [limit] entries, least recently used
/// first out. A failed fetch is not kept, so the next request tries again.
/// Concurrent requests for one URL share a single fetch.
class SnapshotCache<V> {
  SnapshotCache({
    this.limit = 64,
    this.maxAge = const Duration(minutes: 30),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int limit;
  final Duration maxAge;
  final DateTime Function() _now;
  final _entries = <String, (DateTime, Future<V>)>{};

  Future<V> get(String url, Future<V> Function() fetch) {
    final hit = _entries.remove(url);
    if (hit != null && _now().difference(hit.$1) < maxAge) {
      _entries[url] = hit; // most recently used goes to the end
      return hit.$2;
    }
    // The entry goes in before the fetch starts, so that a failure, even a
    // synchronous one, always finds it and takes it out again.
    final result = Completer<V>();
    _entries[url] = (_now(), result.future);
    while (_entries.length > limit) {
      _entries.remove(_entries.keys.first);
    }
    unawaited(() async {
      try {
        result.complete(await fetch());
      } catch (e, st) {
        if (identical(_entries[url]?.$2, result.future)) _entries.remove(url);
        result.completeError(e, st);
      }
    }());
    return result.future;
  }
}
