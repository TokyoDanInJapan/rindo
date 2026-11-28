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
  final abort = Completer<void>();
  final request = http.AbortableRequest('GET', url, abortTrigger: abort.future);
  final response =
      await (() async {
        final streamed = await client.send(request);
        return http.Response.fromStream(streamed);
      })().timeout(
        deadline,
        onTimeout: () {
          abort.complete();
          throw TimeoutException('$resource transfer', deadline);
        },
      );
  if (response.statusCode == 404 && onNotFound != null) return onNotFound();
  if (response.statusCode != 200) {
    throw error('$resource ${response.statusCode}');
  }
  return parse(response.bodyBytes);
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
