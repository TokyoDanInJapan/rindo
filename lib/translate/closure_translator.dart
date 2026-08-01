import 'package:flutter/foundation.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import '../closures/road_closure.dart';

/// Where the translator is in its lifecycle, for the UI to narrate.
enum TranslatorStatus { idle, downloadingModel, ready, failed }

/// On-device ja→en translation of closure text, through Google ML Kit. The
/// models, about 30 MB each way, download once over the network. Translation
/// then works fully offline, which matters in the same dead zones the rest of
/// the app is built for. A failure degrades to the original Japanese and never
/// blocks.
class ClosureTranslator {
  final _translator = OnDeviceTranslator(
    sourceLanguage: TranslateLanguage.japanese,
    targetLanguage: TranslateLanguage.english,
  );
  final _modelManager = OnDeviceTranslatorModelManager();
  final _cache = <String, String>{};

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
    if (_ready) return Future.value(true);
    return _readying ??= _download().whenComplete(() => _readying = null);
  }

  Future<bool> _download() async {
    downloadStartedAt = DateTime.now();
    status.value = TranslatorStatus.downloadingModel;
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
    status.value = _ready ? TranslatorStatus.ready : TranslatorStatus.failed;
    if (!_ready) debugPrint('ClosureTranslator: $lastError');
    return _ready;
  }

  /// One string, ja -> en, cached and never throwing. A failed line comes back
  /// as the original Japanese rather than taking the whole record down with
  /// it. Callers must call [ensureReady] first, because this method alone will
  /// not download the model.
  Future<String> translateText(String ja) async {
    final cached = _cache[ja];
    if (cached != null) return cached;
    try {
      final en = await _translator.translateText(ja);
      _cache[ja] = en;
      return en;
    } catch (_) {
      return ja; // keep the original rather than fail the row
    }
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
      restriction: await translateText(c.restriction),
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

  void dispose() {
    status.dispose();
    // Plugin teardown must never take the app down with it. close() is a
    // platform-channel call whose failure would otherwise surface as an
    // unhandled async error.
    _translator.close().catchError((_) {});
  }
}
