import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';

import '../../closures/closure_repository.dart';
import '../../closures/road_closure.dart';
import '../../closures/search_area.dart';
import '../../translate/ja_en_translator.dart';
import '../../translate/translation_controller.dart';

/// Owns 'which closures, where': the search area, the fetch and its
/// partial-source errors, and the loading pulse. The search area is the rider
/// GPS fix, a dropped pin or a loaded GPX route. Language and translation live
/// in the composed [TranslationController], and the delegates below keep the
/// screen-facing API in one place. The screen listens to this and reads its
/// getters. All the branching between route, point and pin lives here as named
/// getters, instead of being re-derived at every call site.
class ClosuresController extends ChangeNotifier {
  static const pointRadiusKm = 50.0; // circle around rider/pin
  static const routeRadiusKm = 10.0; // corridor around a GPX route

  /// How long a clean fetch stays fresh, and how far the centre may move
  /// before it is refetched anyway.
  static const freshFor = Duration(minutes: 15);
  static const refetchAfterKm = 10.0;

  /// How soon a fetch with a failed source is tried again. Its data is partly
  /// the last data received, so it must not count as fresh for the full
  /// [freshFor]. This is also the floor that stops a GPS fix every few
  /// seconds from refetching over a dead network. Each further partial fetch
  /// in a row doubles the wait, up to [freshFor], so a feed that stays down
  /// is not polled every 30 seconds for the whole ride.
  static const retryPartialAfter = Duration(seconds: 30);

  final ClosureRepository _repo;

  /// Language, translated copies and the model-download lifecycle.
  final TranslationController translation;

  /// Ring pulse played while a fetch is in flight. It is driven here, and the
  /// map's FadeTransition listens to [pulseOpacity].
  final AnimationController pulse;

  // Built once. A CurvedAnimation subscribes to its parent when it is made,
  // so building one per map rebuild leaked a listener on [pulse] each time.
  late final _pulseCurve = CurvedAnimation(
    parent: pulse,
    curve: Curves.easeInOut,
  );

  /// The search disc's opacity while a fetch is in flight.
  late final Animation<double> pulseOpacity = Tween(
    begin: 0.0,
    end: 0.15,
  ).animate(_pulseCurve);

  ClosuresController({
    required TickerProvider vsync,
    ClosureRepository? repository,
    JaEnTranslator? translator,
    DateTime Function()? now,
    bool? english,
  }) : _repo = repository ?? ClosureRepository(),
       translation = TranslationController(
         translator: translator,
         english: english,
       ),
       _now = now ?? DateTime.now,
       pulse = AnimationController(
         vsync: vsync,
         duration: const Duration(milliseconds: 900),
       ) {
    // Translation changes, the English swap-in and the banner status, repaint
    // the same listeners as closure changes.
    translation.addListener(_notify);
  }

  final DateTime Function() _now;

  // In-flight fetches and translations outlive the widget tree on teardown.
  // Notifying after dispose is a debug-mode crash, and so is touching the
  // pulse.
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---- search area
  LatLng? _rider;
  LatLng? _pin;
  List<LatLng>? _route;
  CorridorArea? _corridor; // built once per route, see [CorridorArea]

  // Bumped whenever the search changes shape: a pin dropped or cleared, a
  // route loaded or cleared. A fetch that finishes under an older generation
  // answered a question nobody is asking any more, so it is dropped.
  int _areaGeneration = 0;

  LatLng? get rider => _rider;
  LatLng? get pin => _pin;
  List<LatLng>? get route => _route;
  bool get pinned => _pin != null;
  bool get routeMode => _route != null;

  /// Point mode search centre: the pin wins over the GPS fix. It is null in
  /// route mode, because the corridor has no single centre.
  LatLng? get searchCenter => _pin ?? _rider;

  /// Centre for the per-item distances in the list and detail views. It is
  /// null in route mode, where a distance from a point would mislead.
  LatLng? get distanceCenter => routeMode ? null : searchCenter;

  /// Radius label and ring for the active mode.
  double get activeRadiusKm => routeMode ? routeRadiusKm : pointRadiusKm;

  // ---- data
  bool _loading = false;
  String? _error;
  LatLng? _fetchedAt;
  DateTime? _fetchedTime;
  // Partial fetches in a row, for the retry backoff. 0 after a clean one.
  int _partialStreak = 0;

  // A refresh asked for while a fetch was in flight: null for none, else
  // whether it was forced. It runs as soon as that fetch ends.
  bool? _queuedForce;

  bool get loading => _loading;
  String? get error => _error;

  String get attribution => _repo.attribution;
  Uri get attributionUrl => _repo.attributionUrl;

  // ---- translation delegates, so that call sites keep one surface
  bool get english => translation.english;
  bool get translating => translation.translating;
  List<RoadClosure> get shown => translation.shown;
  TranslatorStatus get translatorStatus => translation.translatorStatus;
  String? get translatorError => translation.translatorError;
  DateTime? get downloadStartedAt => translation.downloadStartedAt;
  JaEnTranslator get translator => translation.translator;
  void toggleLanguage() => translation.toggleLanguage();

  // ---- mutations

  /// New GPS fix, which triggers a refresh. The refresh is forced on the very
  /// first fix, so that closures load immediately. The screen still owns
  /// camera-follow.
  void setRider(LatLng fix) {
    final first = _rider == null;
    _rider = fix;
    _notify();
    refresh(force: first);
  }

  void dropPin(LatLng where) {
    _pin = where;
    _areaGeneration++;
    _notify();
    refresh(force: true);
  }

  void clearPin() {
    if (_pin == null) return;
    _pin = null;
    _areaGeneration++;
    _notify();
    refresh(force: true);
  }

  void loadRoute(List<LatLng> points) {
    _route = points;
    _corridor = CorridorArea(points, routeRadiusKm);
    _pin = null; // the route owns the search now
    _areaGeneration++;
    _notify();
    refresh(force: true);
  }

  void clearRoute() {
    if (_route == null) return;
    _route = null;
    _corridor = null;
    _areaGeneration++;
    _notify();
    refresh(force: true);
  }

  /// Surface an error from the screen, a GPX that failed to parse for example.
  void reportError(String message) {
    _error = message;
    _notify();
  }

  /// Hide the current error banner. It reappears if a later fetch fails again.
  void dismissError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  /// Refetch when nothing was ever fetched, when the centre moved more than
  /// [refetchAfterKm] from the last fetch, or when the data is older than
  /// [freshFor]. A fetch where a source failed is fresh only for
  /// [retryPartialAfter]. A loaded route replaces the point query with its
  /// corridor, where only age and force apply, because the route is static.
  ///
  /// A refresh asked for mid-fetch is queued, not dropped. A pin dropped while
  /// the rider's closures were loading must still load the pin's.
  Future<void> refresh({required bool force}) async {
    if (_disposed) return;
    final corridor = _corridor;
    final center = searchCenter;
    if (corridor == null && center == null) return;
    if (_loading) {
      _queuedForce = (_queuedForce ?? false) || force;
      return;
    }
    final movedKm = corridor != null || _fetchedAt == null
        ? double.infinity
        : const Distance().as(LengthUnit.Kilometer, _fetchedAt!, center!);
    final age = _fetchedTime == null
        ? const Duration(days: 1)
        : _now().difference(_fetchedTime!);
    final freshness = _partialStreak == 0
        ? freshFor
        // Capped shift: 30 s × 2⁶ is already past [freshFor].
        : _min(
            retryPartialAfter * (1 << (_partialStreak - 1).clamp(0, 6)),
            freshFor,
          );
    if (!force && movedKm < refetchAfterKm && age < freshness) return;

    final generation = _areaGeneration;
    _loading = true;
    _error = null;
    _notify();
    // The pulsing disc renders only in point mode, so do not run a ticker for
    // an animation that nothing shows.
    if (corridor == null) unawaited(pulse.repeat(reverse: true));
    try {
      final (all, errors) = await _repo.fetch(
        corridor ?? CircleArea(center!, pointRadiusKm),
      );
      // Superseded by a new pin or route: the queued refresh fetches that.
      if (_disposed || generation != _areaGeneration) return;
      if (center != null && corridor == null) {
        // Distances once each, rather than two per comparison.
        final km = {for (final c in all) c: c.distanceKmFrom(center)};
        all.sort((a, b) => km[a]!.compareTo(km[b]!));
      }
      _fetchedAt = center;
      _fetchedTime = _now();
      _partialStreak = errors.isEmpty ? 0 : _partialStreak + 1;
      // Partial-source failures: show what arrived, but say what is missing.
      _error = errors.isEmpty ? null : errors.join('\n');
      // Hand the list over. The originals show immediately, and the English
      // copies swap in when the translation completes, which is cached and
      // usually instant.
      translation.setSource(all);
      _notify();
    } catch (e) {
      _error = '$e';
      _notify();
    } finally {
      if (!_disposed) {
        pulse
          ..stop()
          ..value = 0;
      }
      _loading = false;
      _notify();
      final queued = _queuedForce;
      _queuedForce = null;
      final superseded = generation != _areaGeneration;
      if (!_disposed && (queued != null || superseded)) {
        unawaited(refresh(force: superseded || queued!));
      }
    }
  }

  static Duration _min(Duration a, Duration b) => a < b ? a : b;

  @override
  void dispose() {
    _disposed = true;
    translation.removeListener(_notify);
    translation.dispose();
    _pulseCurve.dispose();
    pulse.dispose();
    super.dispose();
  }
}
