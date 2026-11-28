import 'package:flutter/foundation.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../closures/road_closure.dart';
import 'restriction_glossary.dart';

/// Where the translator is in its lifecycle, for the UI to narrate.
enum TranslatorStatus { idle, downloadingModel, ready, failed }

/// On-device ja→en translation, through Google ML Kit, for the closure text and
/// the weather report. One instance is shared, because it owns the downloaded
/// models and the string cache. The models, about 30 MB each way, download
/// once over the network. Translation
/// then works fully offline, which matters in the same dead zones the rest of
/// the app is built for. A failure degrades to the original Japanese and never
/// blocks.
class JaEnTranslator {
  /// The ML Kit objects and the cache size are injectable for the tests. The
  /// app uses the defaults.
  JaEnTranslator({
    OnDeviceTranslator? translator,
    OnDeviceTranslatorModelManager? modelManager,
    this.cacheLimit = 2000,
  }) : _translator =
           translator ??
           OnDeviceTranslator(
             sourceLanguage: TranslateLanguage.japanese,
             targetLanguage: TranslateLanguage.english,
           ),
       _modelManager = modelManager ?? OnDeviceTranslatorModelManager();

  final OnDeviceTranslator _translator;
  final OnDeviceTranslatorModelManager _modelManager;

  /// Most strings the cache keeps. The least recently used goes first. A long
  /// ride through many prefectures would otherwise grow it without limit.
  final int cacheLimit;

  // Futures, not results. A fetch of 100 closures asks for the same source
  // name and restriction 100 times at once, before any answer is back, and a
  // cache of results would send every one of them through the platform
  // channel. A map literal keeps insertion order, and that is the LRU order: a
  // hit is moved to the end.
  final _cache = <String, Future<String>>{};

  // The screen can go away while a download or a translation is in flight.
  bool _disposed = false;

  /// Narratable state, plus the actual error text when
  /// [TranslatorStatus.failed]. Silent failure made 'it is just Japanese'
  /// undiagnosable in the field.
  final status = ValueNotifier<TranslatorStatus>(TranslatorStatus.idle);
  String? lastError;
  DateTime? downloadStartedAt; // set while status == downloadingModel

  bool _ready = false;
  Future<bool>? _readying;

  /// Downloads the Japanese and English models if they are not on the device
  /// yet. It is safe to call repeatedly, and concurrent callers share one
  /// attempt.
  Future<bool> ensureReady() {
    // Not after dispose: there is nobody left to show the result to, and a
    // 'true' here would send callers on to translateText.
    if (_disposed) return Future.value(false);
    if (_ready) return Future.value(true);
    return _readying ??= _download().whenComplete(() => _readying = null);
  }

  Future<bool> _download() async {
    downloadStartedAt = DateTime.now();
    _setStatus(TranslatorStatus.downloadingModel);
    try {
      for (final lang in [
        TranslateLanguage.japanese.bcpCode,
        TranslateLanguage.english.bcpCode,
      ]) {
        if (!await _modelManager.isModelDownloaded(lang)) {
          // isWifiRequired defaults to TRUE, which silently declines the
          // download on cellular, the opposite of what a touring app wants.
          // The timeout stops a dead network from wedging the UI state, and
          // the next fetch or toggle retries.
          final ok = await _modelManager
              .downloadModel(lang, isWifiRequired: false)
              .timeout(const Duration(seconds: 90));
          if (!ok) throw Exception('downloadModel($lang) returned false');
        }
      }
      // downloadModel has been seen lying in both directions, so ready
      // means the models are verifiably on the device.
      _ready =
          await _modelManager.isModelDownloaded(
            TranslateLanguage.japanese.bcpCode,
          ) &&
          await _modelManager.isModelDownloaded(
            TranslateLanguage.english.bcpCode,
          );
      lastError = _ready ? null : 'models missing after download';
    } catch (e) {
      _ready = false; // retry on the next fetch/toggle
      lastError = '$e';
    }
    downloadStartedAt = null;
    _setStatus(_ready ? TranslatorStatus.ready : TranslatorStatus.failed);
    if (!_ready) debugPrint('JaEnTranslator: $lastError');
    return _ready && !_disposed;
  }

  /// A download can outlive the screen by up to its 90 second timeout. Writing
  /// to the disposed notifier then throws in debug builds, and it would throw
  /// outside [_download]'s try block, into a future that nobody awaits.
  void _setStatus(TranslatorStatus s) {
    if (!_disposed) status.value = s;
  }

  /// One string, ja -> en, cached and never throwing. A failed line comes back
  /// as the original Japanese rather than taking the whole record down with
  /// it. Callers must call [ensureReady] first, because this method alone will
  /// not download the model.
  ///
  /// Concurrent requests for the same string share one platform call. A
  /// failed call is dropped from the cache, so the next request tries again.
  Future<String> translateText(String ja) {
    // The native side creates a translator on demand for any id it does not
    // know. A call sent after close() would therefore build a new native
    // translator that nothing ever closes.
    if (_disposed) return Future.value(ja);

    final cached = _cache.remove(ja);
    if (cached != null) {
      _cache[ja] = cached; // most recently used goes to the end
      return cached;
    }

    late final Future<String> call;
    // Future.sync turns a synchronous throw into a failed future, so both
    // kinds of failure reach onError, and reach it after `call` is assigned.
    call = Future.sync(() => _translator.translateText(ja)).then(
      (en) => en,
      onError: (Object _) {
        // Only if the entry is still this call: it may have been evicted and
        // replaced by a newer attempt, which must stay.
        if (identical(_cache[ja], call)) _cache.remove(ja);
        return ja; // keep the original rather than fail the row
      },
    );
    _cache[ja] = call;
    while (_cache.length > cacheLimit) {
      _cache.remove(_cache.keys.first);
    }
    return call;
  }

  /// A display copy of [c] with its Japanese text fields translated. The
  /// identity fields pass through untouched: id, geometry, URLs and dates.
  Future<RoadClosure> translateClosure(RoadClosure c) async {
    if (!await ensureReady()) return c;
    return RoadClosure(
      id: c.id,
      point: c.point,
      roadName: await translateText(c.roadName),
      section: c.section == null ? null : await translateText(c.section!),
      // Never machine-translated: see restriction_glossary.dart.
      restriction: await restrictionInEnglish(c.restriction, translateText),
      cause: c.cause == null ? null : await translateText(c.cause!),
      period: c.period == null ? null : await translateText(c.period!),
      sourceName: await translateText(c.sourceName),
      sourceUrl: c.sourceUrl,
      lines: c.lines,
      validFrom: c.validFrom,
      validUntil: c.validUntil,
      isSeasonal: c.isSeasonal,
      isFullClosure: c.isFullClosure,
    );
  }

  /// Safe to call with work in flight, and safe to call twice.
  ///
  /// Translations already sent reach the native side before the close does,
  /// because the channel keeps its order. They finish or fail there, and a
  /// failure comes back as the original Japanese. [translateText] sends
  /// nothing after this point. That matters to a closure half way through its
  /// fields, whose next field would otherwise go out after the close.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    status.dispose();
    _cache.clear();
    // Plugin teardown must never take the app down with it. close() is a
    // platform-channel call whose failure would otherwise surface as an
    // unhandled async error, and a synchronous throw is caught the same way.
    Future.sync(_translator.close).catchError((_) {});
  }
}
