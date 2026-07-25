import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';

import '../closures/road_closure.dart';
import 'closure_translator.dart';

/// Language + translation state for the closure list, split out of
/// ClosuresController: which language is active, the English copies of the
/// current fetch, the in-flight translation flag, and the translator's
/// model-download lifecycle (surfaced to the banner).
///
/// Owns the "superseded fetch" rule: a translation result only lands if the
/// source list it was started from is still the current one - otherwise a
/// slow translation of an old fetch would overwrite a newer list.
class TranslationController extends ChangeNotifier {
  TranslationController({ClosureTranslator? translator, bool? english})
    : _translator = translator ?? ClosureTranslator(),
      _english = english ?? prefersEnglish(PlatformDispatcher.instance.locale) {
    // Model download/failure transitions must repaint the banner.
    _translator.status.addListener(_notify);
  }

  final ClosureTranslator _translator;

  // In-flight translations outlive the widget tree on teardown; notifying
  // after dispose is a debug-mode crash.
  bool _disposed = false;

  bool _english;
  bool _translating = false;
  List<RoadClosure> _source = const [];
  List<RoadClosure> _translated = const [];

  /// Language default: follow the phone. A Japanese-language OS reads the
  /// sources natively, so translation (and the English-labelled basemap)
  /// would only get in the way; every other language starts in English.
  /// The あ/EN FAB still toggles freely either way.
  @visibleForTesting
  static bool prefersEnglish(Locale locale) => locale.languageCode != 'ja';

  bool get english => _english;
  bool get translating => _translating;

  /// What the map/list/detail display: English copies when selected, else
  /// the untranslated originals.
  List<RoadClosure> get shown => _english ? _translated : _source;

  /// The on-device translator itself, for text that isn't a closure - the
  /// weather report. Shared deliberately: it owns the downloaded model and the
  /// string cache, so a second instance would mean a second ~30 MB download.
  ClosureTranslator get translator => _translator;

  // Translator pass-throughs for the banner.
  TranslatorStatus get translatorStatus => _translator.status.value;
  String? get translatorError => _translator.lastError;
  DateTime? get downloadStartedAt => _translator.downloadStartedAt;

  /// A fetch landed: show the originals immediately; English copies swap in
  /// when the (cached, usually instant) translation completes.
  void setSource(List<RoadClosure> closures) {
    _source = closures;
    _translated = closures;
    _notify();
    _retranslate();
  }

  void toggleLanguage() {
    _english = !_english;
    _translated = _source; // show originals until translation lands
    _notify();
    _retranslate();
  }

  /// Replace [_translated] with English copies of the current list. No-op in
  /// Japanese; if the list changes mid-flight the stale result is dropped.
  Future<void> _retranslate() async {
    if (!_english || _source.isEmpty) return;
    final raw = _source;
    _translating = true;
    _notify();
    try {
      // Concurrent: each closure is ~6 platform-channel calls; sequentially
      // that made the first English swap-in linear in the list length.
      final out = await Future.wait(raw.map(_translator.translateClosure));
      if (!identical(raw, _source)) return; // superseded by a newer fetch
      _translated = out;
      _notify();
    } finally {
      _translating = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _translator.status.removeListener(_notify);
    _translator.dispose();
    super.dispose();
  }
}
