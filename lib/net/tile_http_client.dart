import 'dart:io';

import 'package:http/http.dart';
import 'package:http/io_client.dart';
import 'package:http/retry.dart';

import 'response_copy.dart';

/// HTTP client for map-tile fetches: bounded connections, a hard per-request
/// deadline, and retries for transient socket failures.
///
/// flutter_map's default tile provider awaits `httpClient.send()` (and reads
/// the body) with no timeout, so a request that stalls on a half-open socket -
/// common on mobile after a network handover or doze - hangs *forever*. A hung
/// tile never fires `errorTileCallback`, so none of the screen's recovery
/// paths (the offline banner, the "tap to retry" placeholders, the re-key on
/// the next JMA success) can even see it: the tile just pulses until the whole
/// process is killed. That is the "base map goes blank, only a full restart
/// fixes it" failure.
///
/// Wrapping every tile request in a deadline turns that invisible hang into an
/// ordinary error the existing machinery already handles. [RetryClient] keeps
/// parity with flutter_map's default (retry on 503).
///
/// The connection cap and socket-error retry exist for the zoom-out burst: a
/// pinch from z10 out to z6 re-keys all six radar frame layers at every even
/// zoom crossing, landing a few hundred tile requests on this client within a
/// second. dart:io's default HttpClient has no per-host connection limit, so
/// each request opens its own socket, and on a marginal mobile link the
/// connect storm itself starts failing - SocketException "No route to host"
/// (errno 113) - while requests on already-warm connections keep succeeding.
/// Capping connections per host queues the burst onto a few keep-alive
/// sockets instead, and retrying socket-level errors (tile fetches are
/// idempotent GETs) absorbs the stragglers, so a transient connect failure no
/// longer becomes a dead tile the user has to tap to revive.
Client tileHttpClient() {
  final io = HttpClient()
    // Small per-host cap: enough parallelism for tile bursts without the
    // connect storm this cap exists to prevent. Radar sizes it - the whole
    // visible frame (~100 tiny tiles; the other frames mount one at a time,
    // see radar_map_view.dart) lands on www.jma.go.jp at once, and queue
    // wait counts against the deadline below, so the queue must drain a
    // full frame within it even on a slow link. 6 proved too narrow there
    // (tail-of-queue timeouts); 8 clears it while staying near browser
    // etiquette for the OSM France subdomains.
    ..maxConnectionsPerHost = 8
    // A connect that black-holes (SYN never answered) fails here and gets
    // retried on a fresh socket, instead of burning the whole 20 s request
    // deadline first.
    ..connectionTimeout = const Duration(seconds: 10);
  return RetryClient(
    _TimeoutClient(IOClient(io)),
    // On top of the default 503 retry. Deliberately NOT retrying the
    // deadline timeouts below: a 20 s stall should surface as a failed tile
    // for the screen's recovery machinery, not silently retry for a minute.
    whenError: (e, _) => e is SocketException || e is ClientException,
  );
}

class _TimeoutClient extends BaseClient {
  _TimeoutClient(this._inner);

  final Client _inner;

  // Long enough for a slow-but-alive tile server, short enough that a dead
  // connection surfaces as a retryable error instead of a permanent hole.
  static const _untilHeaders = Duration(seconds: 20); // connect + headers
  static const _betweenChunks = Duration(seconds: 20); // stall mid-body

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    final response = await _inner.send(request).timeout(_untilHeaders);
    return response.copyWithStream(response.stream.timeout(_betweenChunks));
  }

  @override
  void close() => _inner.close();
}
