import 'dart:ui' show Locale, PlatformDispatcher;

import 'package:flutter/foundation.dart';

import '../closures/road_closure.dart';
import 'closure_translator.dart';

/// Language and translation state for the closure list, split out of
/// ClosuresController. It holds which language is active, the English copies
/// of the current fetch, the in-flight translation flag, and the translator's
/// model-download lifecycle, which is surfaced to the banner.
///
/// It owns the 'superseded fetch' rule. A translation result lands only if the
/// source list it was started from is still the current one. Otherwise a slow
/// translation of an old fetch would overwrite a newer list.
class TranslationController extends ChangeNotifier {
  TranslationController({ClosureTranslator? translator, bool? english})
    : _translator = translator ?? ClosureTranslator(),
      _english = english ?? prefersEnglish(PlatformDispatcher.instance.locale) {
    // Model download and failure transitions must repaint the banner.
    _translator.status.addListener(_notify);
  }

  final ClosureTranslator _translator;

  // In-flight translations outlive the widget tree on teardown, and notifying
  // after dispose is a debug-mode crash.
  bool _disposed = false;

  bool _english;
  bool _translating = false;
  List<RoadClosure> _source = const [];
  List<RoadClosure> _translated = const [];

  /// The language default follows the phone. A Japanese-language OS reads the
  /// sources natively, so the translation, and the English-labelled base map,
  /// would only get in the way. Every other language starts in English. The
  /// あ/EN button still toggles freely either way.
  @visibleForTesting
  static bool prefersEnglish(Locale locale) => locale.languageCode != 'ja';

  bool get english => _english;
  bool get translating => _translating;

  /// What the map, list and detail views display: the English copies when
  /// English is selected, and the untranslated originals otherwise.
  List<RoadClosure> get shown => _english ? _translated : _source;

  /// The on-device translator itself, for text that is not a closure, namely
  /// the weather report. It is shared deliberately. It owns the downloaded
  /// model and the string cache, so a second instance would mean a second
  /// 30 MB download.
  ClosureTranslator get translator => _translator;

  // Translator pass-throughs for the banner.
  TranslatorStatus get translatorStatus => _translator.status.value;
  String? get translatorError => _translator.lastError;
  DateTime? get downloadStartedAt => _translator.downloadStartedAt;

  /// A fetch landed, so show the originals immediately. The English copies
  /// swap in when the translation completes, which is cached and usually
  /// instant.
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

  /// Replace [_translated] with English copies of the current list. It does
  /// nothing in Japanese. If the list changes mid-flight, the stale result is
  /// dropped.
  Future<void> _retranslate() async {
    if (!_english || _source.isEmpty) return;
    final raw = _source;
    _translating = true;
    _notify();
    try {
      // Run these concurrently. Each closure is about 6 platform-channel
      // calls, and in series that made the first English swap-in linear in the
      // list length.
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
