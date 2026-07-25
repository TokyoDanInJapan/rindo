import 'dart:async';
import 'dart:io';

import 'package:http/http.dart';
import 'package:http/io_client.dart';
import 'package:http/retry.dart';

import 'response_copy.dart';

/// HTTP client for map-tile fetches: bounded connections, a hard per-request
/// deadline, retries for transient socket failures, and failures re-typed so
/// flutter_map can't quietly turn them into blank tiles.
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
///
/// The outermost wrapper re-types what's left over - see [TileFetchException]
/// for why a dropped connection would otherwise be read as "this tile is empty".
///
/// [transport] replaces the dart:io transport, so tests can drive the whole
/// wrapper chain (retries, deadline, error surfacing) without a socket.
Client tileHttpClient({Client? transport}) {
  final inner =
      transport ??
      IOClient(
        HttpClient()
          // Small per-host cap: enough parallelism for tile bursts without the
          // connect storm this cap exists to prevent. Radar sizes it - the
          // whole visible frame (~100 tiny tiles; the other frames mount one
          // at a time, see radar_map_view.dart) lands on www.jma.go.jp at
          // once, and queue wait counts against the deadline below, so the
          // queue must drain a full frame within it even on a slow link. 6
          // proved too narrow there (tail-of-queue timeouts); 8 clears it
          // while staying near browser etiquette for the OSM France
          // subdomains.
          ..maxConnectionsPerHost = 8
          // A connect that black-holes (SYN never answered) fails here and
          // gets retried on a fresh socket, instead of burning the whole 20 s
          // request deadline first.
          ..connectionTimeout = const Duration(seconds: 10),
      );
  return _SurfacedFailureClient(
    RetryClient(
      _TimeoutClient(inner),
      // On top of the default 503 retry. Deliberately NOT retrying the
      // deadline timeouts below: a 20 s stall should surface as a failed tile
      // for the screen's recovery machinery, not silently retry for a minute.
      whenError: (e, _) => e is SocketException || e is ClientException,
    ),
  );
}

/// A tile transport failure that flutter_map cannot mistake for an empty tile.
///
/// flutter_map decides what a failed tile fetch *means* by sniffing the
/// exception message: its network image provider treats any [ClientException]
/// whose message contains "closed" or "cancel" as a planned cancellation and
/// resolves the tile as a **successful** transparent image. That is right for
/// the one case it was written for - the HTTP client being closed while the map
/// is torn down - but dart:io words ordinary mid-request network loss the same
/// way ("Connection closed before full header was received", "Connection closed
/// while receiving data"), which is exactly what a mobile link does when it
/// drops a handover or wakes from doze.
///
/// A tile that "succeeded" as blank is unrecoverable: `TileImage.loadError`
/// stays false so `errorTileCallback` never fires, so there is no failed-tile
/// banner, no tappable placeholder, and nothing to tell ConnectivityMonitor an
/// outage is underway - and TileImageManager will not re-request a tile that
/// finished loading. The hole is silent and permanent, the same end state as the
/// image-cache adoption bug in rekey_safe_tile_provider.dart.
///
/// So the tile client re-types those failures on the way out. Nothing else
/// changes: [toString] is the wrapped exception's verbatim, because every
/// consumer downstream classifies errors textually (net_error.dart's
/// connectivity markers, TileStatusMonitor's 404 filter, the debug sheet's last
/// error line) and should keep seeing exactly what it saw before.
class TileFetchException implements Exception {
  TileFetchException(this.cause);

  final ClientException cause;

  @override
  String toString() => cause.toString();
}

/// Wraps tile failures in [TileFetchException] so they reach the screen's
/// recovery paths instead of being swallowed as blank tiles.
///
/// Sits *outside* [RetryClient] on purpose: a dropped connection is worth
/// retrying first, and the retry predicate matches on [ClientException], so
/// re-typing any earlier would disable it. Only a failure that survived every
/// retry gets re-typed.
class _SurfacedFailureClient extends BaseClient {
  _SurfacedFailureClient(this._inner);

  final Client _inner;

  /// The one genuine cancellation: our own [Client.close] during teardown.
  /// flutter_map should keep quietly ignoring this one.
  static const _clientClosed = 'Client is already closed';

  static Object _surface(Object error) {
    if (error is! ClientException) return error;
    // A pruned tile's aborted request is a planned cancellation, and the asset
    // monitor tells cancellations from failures by type - preserve it.
    if (error is RequestAbortedException) return error;
    if (error.message.contains(_clientClosed)) return error;
    return TileFetchException(error);
  }

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    final StreamedResponse response;
    try {
      response = await _inner.send(request);
    } catch (e, st) {
      Error.throwWithStackTrace(_surface(e), st);
    }
    // Connection loss part-way through a tile body arrives on the stream, not
    // from send(), and is the wording most likely to be mistaken for a
    // cancellation - so it needs the same treatment.
    return response.copyWithStream(
      response.stream.transform(
        StreamTransformer.fromHandlers(
          handleError: (e, st, sink) => sink.addError(_surface(e), st),
        ),
      ),
    );
  }

  @override
  void close() => _inner.close();
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
