import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:http/http.dart';

/// Base-map tiles the rider has already seen, kept on disk, so that the map
/// still shows them in a dead zone and the volunteer-run tile servers are not
/// asked for the same tile on every launch.
///
/// Only CyclOSM tiles are kept. OpenStreetMap France hosts them for free,
/// non-profit apps, and the tile usage policy that cyclosm.org points to asks
/// clients to cache by the HTTP caching headers and to revalidate with the
/// ETag. Esri's World Street Map, the English base map, is never kept. Esri's
/// terms allow storing its tiles only through Esri's own software.
///
/// The policy also forbids bulk downloading, so nothing here fetches a tile
/// that the map did not ask for.
///
/// The rules:
///
/// - A tile is fresh for as long as its `Cache-Control: max-age` says, less
///   its `Age`, or until its `Expires`. CyclOSM sends 24 hours. A fresh tile
///   never touches the network.
/// - An expired tile is revalidated with `If-None-Match`. A 304 renews it for
///   another lifetime without a download.
/// - An expired tile is served anyway when the network fails, the server
///   answers 5xx or the new transfer breaks off, because an old map is far
///   better than none in a dead zone. A request that the map has cancelled is
///   never answered from the disk.
/// - Only complete 200 image responses are stored. An error, a cancelled or
///   cut-off transfer, or a `no-store` response never is.
/// - The cache holds about [TileDiskCache.maxBytes]. The least recently used
///   tiles go first.
///
/// The client sits *outside* the asset monitor, so the debug sheet still
/// shows only real network traffic.
class CachingTileClient extends BaseClient {
  CachingTileClient(this._inner, this._cache, {DateTime Function()? now})
    : _now = now ?? DateTime.now;

  final Client _inner;
  final TileDiskCache _cache;
  final DateTime Function() _now;

  /// What the cache has done, for the debug sheet.
  final stats = TileCacheStats();

  static const _host = 'tile-cyclosm.openstreetmap.fr';

  /// The freshness of a response whose headers say nothing about it. The
  /// tile usage policy asks for at least 7 days in that case.
  static const defaultLifetime = Duration(days: 7);

  /// The cache key for [url], or null if the cache must not keep it. The
  /// subdomains a, b and c serve the same tiles, so they share one key.
  static String? keyFor(Uri url) {
    if (url.host != _host && !url.host.endsWith('.$_host')) return null;
    final segs = url.pathSegments;
    if (segs.length < 3) return null;
    final [z, x, y] = segs.sublist(segs.length - 3);
    final yNum = y.split('.').first;
    if ([z, x, yNum].any((s) => int.tryParse(s) == null)) return null;
    return 'cyclosm-$z-$x-$yNum';
  }

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    final key = request.method == 'GET' ? keyFor(request.url) : null;
    if (key == null) return _inner.send(request);

    // flutter_map aborts the request for a tile it no longer needs. Note
    // when that happens, so that the disk never answers for it afterwards.
    var aborted = false;
    if (request case Abortable(:final abortTrigger?)) {
      unawaited(abortTrigger.then((_) => aborted = true, onError: (_) {}));
    }

    final cached = await _cache.read(key);
    final now = _now();
    if (cached != null && now.isBefore(cached.expires)) {
      stats.hits++;
      _cache.touch(key);
      return _respond(cached.bytes, request);
    }
    if (cached == null) {
      return _storeWhileStreaming(key, await _inner.send(request), now);
    }
    return _revalidate(key, cached, request, now, () => aborted);
  }

  /// An expired tile: ask the server whether it changed, and fall back to the
  /// stored copy when anything goes wrong. The new body is read in full
  /// before this answers, so that a transfer that breaks off part way still
  /// ends with the old tile rather than an error. Tiles are about 30 KB.
  Future<StreamedResponse> _revalidate(
    String key,
    CachedTile cached,
    BaseRequest request,
    DateTime now,
    bool Function() aborted,
  ) async {
    StreamedResponse fromDisk({required bool stale}) {
      if (aborted()) throw RequestAbortedException(request.url);
      stale ? stats.offline++ : stats.revalidated++;
      _cache.touch(key);
      return _respond(cached.bytes, request);
    }

    final etag = cached.etag;
    if (etag != null) request.headers['If-None-Match'] = etag;
    final StreamedResponse response;
    final Uint8List body;
    try {
      response = await _inner.send(request);
      body = await response.stream.toBytes();
    } on RequestAbortedException {
      rethrow;
    } catch (_) {
      return fromDisk(stale: true);
    }
    final headers = response.headers;
    final status = response.statusCode;

    if (status == 304) {
      if (_control(headers).contains('no-store')) {
        unawaited(_cache.remove(key));
      } else {
        final lifetime = _lifetime(headers) ?? cached.lifetime;
        unawaited(_cache.renew(key, cached, now.add(lifetime), lifetime));
      }
      return fromDisk(stale: false);
    }
    if (status >= 500) return fromDisk(stale: true);
    final length = response.contentLength;
    if (status == 200 && length != null && body.length != length) {
      return fromDisk(stale: true); // cut off
    }
    if (status == 200 && _storable(headers) && body.isNotEmpty) {
      _store(key, body, headers, now);
    }
    return StreamedResponse(
      Stream.value(body),
      status,
      contentLength: body.length,
      request: response.request,
      headers: headers,
      reasonPhrase: response.reasonPhrase,
    );
  }

  /// A tile with no stored copy: hand the body on as it arrives, and store
  /// it once it has arrived whole. A transfer that fails, that is cut off, or
  /// that the map cancels is never stored.
  StreamedResponse _storeWhileStreaming(
    String key,
    StreamedResponse response,
    DateTime now,
  ) {
    if (response.statusCode != 200 || !_storable(response.headers)) {
      return response;
    }
    final body = BytesBuilder(copy: false);
    var failed = false;
    final length = response.contentLength;
    final stream = response.stream.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          body.add(chunk);
          sink.add(chunk);
        },
        handleError: (e, st, sink) {
          failed = true;
          sink.addError(e, st);
        },
        handleDone: (sink) {
          sink.close();
          final bytes = body.takeBytes();
          final whole = length == null || bytes.length == length;
          if (!failed && whole && bytes.isNotEmpty) {
            _store(key, bytes, response.headers, now);
          }
        },
      ),
    );
    return StreamedResponse(
      stream,
      response.statusCode,
      contentLength: length,
      request: response.request,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  void _store(
    String key,
    Uint8List bytes,
    Map<String, String> headers,
    DateTime now,
  ) {
    stats.stored++;
    final lifetime = _lifetime(headers) ?? defaultLifetime;
    unawaited(
      _cache.write(
        key,
        bytes,
        expires: now.add(lifetime),
        lifetime: lifetime,
        etag: headers['etag'],
      ),
    );
  }

  /// Cache-Control directives are case-insensitive.
  static String _control(Map<String, String> headers) =>
      (headers['cache-control'] ?? '').toLowerCase();

  static bool _storable(Map<String, String> headers) =>
      (headers['content-type'] ?? '').toLowerCase().startsWith('image/') &&
      !_control(headers).contains('no-store');

  /// How long a response stays fresh, or null if its headers do not say.
  /// `no-cache` means revalidate every time. `max-age` wins over `Expires`,
  /// as in HTTP itself, and counts from when the response was generated, so
  /// the time it already spent in an upstream cache (`Age`) is taken off.
  static Duration? _lifetime(Map<String, String> headers) {
    final control = _control(headers);
    if (control.contains('no-cache')) return Duration.zero;
    final maxAge = RegExp(r'max-age=(\d+)').firstMatch(control)?.group(1);
    if (maxAge != null) {
      final age = int.tryParse(headers['age'] ?? '') ?? 0;
      return Duration(seconds: max(0, int.parse(maxAge) - age));
    }
    final expires = _date(headers['expires']);
    if (expires == null) return null;
    // Against the server's own clock, so that a skewed phone clock does not
    // matter.
    final sent = _date(headers['date']) ?? DateTime.now();
    final left = expires.difference(sent);
    return left.isNegative ? Duration.zero : left;
  }

  static DateTime? _date(String? value) {
    if (value == null) return null;
    try {
      return HttpDate.parse(value);
    } on FormatException {
      return null;
    } on HttpException {
      return null;
    }
  }

  static StreamedResponse _respond(Uint8List bytes, BaseRequest request) =>
      StreamedResponse(
        Stream.value(bytes),
        200,
        contentLength: bytes.length,
        request: request,
        headers: const {'content-type': 'image/png'},
      );

  @override
  void close() => _inner.close();
}

/// Counters for the debug sheet. [hits] were served without the network,
/// [revalidated] needed only a 304, [offline] were expired tiles served
/// because the network or the server failed, and [stored] were saved.
class TileCacheStats {
  int hits = 0, revalidated = 0, offline = 0, stored = 0;

  @override
  String toString() =>
      'hits $hits · 304 $revalidated · offline $offline · stored $stored';
}

/// One stored tile: its bytes, when it stops being fresh, how long it stays
/// fresh each time (so that a 304 without caching headers renews it for the
/// same period), and its ETag.
class CachedTile {
  const CachedTile(this.bytes, this.expires, this.lifetime, this.etag);

  final Uint8List bytes;
  final DateTime expires;
  final Duration lifetime;
  final String? etag;
}

/// The tile files. Each tile is one file: a line of JSON metadata, then the
/// image bytes. A file is written under a unique temporary name and then
/// renamed, so a crash mid-write never leaves a half tile behind. A file that
/// cannot be read is deleted and treated as missing.
///
/// Every operation swallows its own I/O errors. A full disk or a cache
/// directory that the system cleared must never break the map, only the
/// caching.
class TileDiskCache {
  TileDiskCache(
    Future<Directory> root, {
    this.maxBytes = 100 * 1024 * 1024,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now,
       // No cache directory, for whatever reason, means no cache. It must
       // not mean an unhandled error.
       _dir = root
           .then((r) => Directory('${r.path}/tiles').create(recursive: true))
           .then<Directory?>((d) => d, onError: (Object _) => null);

  /// Most bytes on disk. Trimming takes the total down to 90% of this.
  final int maxBytes;
  final DateTime Function() _now;
  final Future<Directory?> _dir;

  // Trims run at most once a minute, and after every 50 writes. A trim that
  // the minute holds back is scheduled for when the minute is up, so that
  // the limit holds even when the writes then stop.
  static const _trimEvery = Duration(minutes: 1);
  static const _writesPerTrim = 50;
  int _writesSinceTrim = 0;
  DateTime? _lastTrim;
  Future<void>? _trimming;
  Timer? _trimTimer;

  // Makes each temporary file name unique, even for two writes of one tile
  // in the same microsecond.
  int _tmpSeq = 0;

  // A temporary file younger than this may still be being written, so a trim
  // leaves it alone. An older one is left over from a crash.
  static const _tmpGrace = Duration(minutes: 10);

  Future<File?> _file(String key) async {
    final dir = await _dir;
    return dir == null ? null : File('${dir.path}/$key');
  }

  Future<CachedTile?> read(String key) async {
    final file = await _file(key);
    if (file == null) return null;
    try {
      final data = await file.readAsBytes();
      final newline = data.indexOf(0x0A);
      if (newline < 0) throw const FormatException('no header');
      final meta = jsonDecode(utf8.decode(data.sublist(0, newline))) as Map;
      final bytes = Uint8List.sublistView(data, newline + 1);
      if (bytes.isEmpty) throw const FormatException('no image');
      return CachedTile(
        bytes,
        DateTime.fromMillisecondsSinceEpoch(meta['e'] as int),
        Duration(seconds: meta['l'] as int),
        meta['t'] as String?,
      );
    } on PathNotFoundException {
      return null;
    } catch (_) {
      unawaited(_delete(file));
      return null;
    }
  }

  Future<void> write(
    String key,
    Uint8List bytes, {
    required DateTime expires,
    required Duration lifetime,
    String? etag,
  }) async {
    final file = await _file(key);
    if (file == null) return;
    final header = utf8.encode(
      '${jsonEncode({'e': expires.millisecondsSinceEpoch, 'l': lifetime.inSeconds, 't': etag})}\n',
    );
    final tmp = File(
      '${file.path}.${_tmpSeq++}-${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await tmp.writeAsBytes([...header, ...bytes], flush: true);
      await tmp.rename(file.path);
    } catch (_) {
      unawaited(_delete(tmp));
      return;
    }
    if (++_writesSinceTrim >= _writesPerTrim) _scheduleTrim();
  }

  /// Keep [cached] for another [lifetime], after a 304.
  Future<void> renew(
    String key,
    CachedTile cached,
    DateTime expires,
    Duration lifetime,
  ) => write(
    key,
    cached.bytes,
    expires: expires,
    lifetime: lifetime,
    etag: cached.etag,
  );

  /// Forget [key], after a 304 that says `no-store`.
  Future<void> remove(String key) async {
    final file = await _file(key);
    if (file != null) await _delete(file);
  }

  /// Mark [key] as recently used, so that trimming keeps it.
  void touch(String key) => unawaited(() async {
    final file = await _file(key);
    try {
      await file?.setLastModified(_now());
    } catch (_) {}
  }());

  void _scheduleTrim() {
    if (_trimTimer != null) return;
    final last = _lastTrim;
    final wait = last == null
        ? Duration.zero
        : _trimEvery - _now().difference(last);
    if (wait <= Duration.zero) {
      unawaited(trim());
    } else {
      _trimTimer = Timer(wait, () {
        _trimTimer = null;
        unawaited(trim(force: true));
      });
    }
  }

  /// Delete the least recently used tiles until the total is at most 90% of
  /// [maxBytes]. Runs at most once a minute, unless [force] is set.
  Future<void> trim({bool force = false}) {
    final last = _lastTrim;
    if (!force && last != null && _now().difference(last) < _trimEvery) {
      return Future.value();
    }
    return _trimming ??= _trim().whenComplete(() => _trimming = null);
  }

  Future<void> _trim() async {
    _lastTrim = _now();
    _writesSinceTrim = 0;
    try {
      final dir = await _dir;
      if (dir == null) return;
      final files = <(File, FileStat)>[];
      var total = 0;
      await for (final e in dir.list()) {
        if (e is! File) continue;
        final stat = await e.stat();
        if (e.path.endsWith('.tmp')) {
          // File times are the real clock's, not the injected one.
          final age = DateTime.now().difference(stat.modified);
          if (age > _tmpGrace) await _delete(e);
          continue;
        }
        files.add((e, stat));
        total += stat.size;
      }
      if (total <= maxBytes) return;
      files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      final target = maxBytes * 9 ~/ 10;
      for (final (file, stat) in files) {
        if (total <= target) break;
        await _delete(file);
        total -= stat.size;
      }
    } catch (_) {
      // Trimming is housekeeping. It tries again after later writes.
    }
  }

  static Future<void> _delete(File f) async {
    try {
      await f.delete();
    } catch (_) {}
  }
}
