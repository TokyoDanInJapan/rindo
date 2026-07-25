import 'package:flutter/widgets.dart';
import 'package:latlong2/latlong.dart';

import '../../closures/closure_repository.dart';
import '../../closures/road_closure.dart';
import '../../translate/closure_translator.dart';
import '../../translate/translation_controller.dart';

/// Owns "which closures, where": the search area (rider GPS / dropped pin /
/// loaded GPX route), the fetch and its partial-source errors, and the
/// loading pulse. Language and translation live in the composed
/// [TranslationController]; the delegates below keep the screen-facing API
/// in one place. The screen listens to this and reads its getters; all the
/// route-vs-point-vs-pin branching lives here as named getters instead of
/// being re-derived at every call site.
class ClosuresController extends ChangeNotifier {
  static const pointRadiusKm = 50.0; // circle around rider/pin
  static const routeRadiusKm = 10.0; // corridor around a GPX route

  final ClosureRepository _repo;

  /// Language + translated copies + model-download lifecycle.
  final TranslationController translation;

  /// Ring pulse played while a fetch is in flight. Driven here; the map's
  /// FadeTransition listens to it directly.
  final AnimationController pulse;

  ClosuresController({
    required TickerProvider vsync,
    ClosureRepository? repository,
    ClosureTranslator? translator,
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
    // Translation changes (the English swap-in, banner status) repaint the
    // same listeners as closure changes.
    translation.addListener(_notify);
  }

  final DateTime Function() _now;

  // In-flight fetches/translations outlive the widget tree on teardown;
  // notifying (or touching the pulse) after dispose is a debug-mode crash.
  bool _disposed = false;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---- search area
  LatLng? _rider;
  LatLng? _pin;
  List<LatLng>? _route;

  LatLng? get rider => _rider;
  LatLng? get pin => _pin;
  List<LatLng>? get route => _route;
  bool get pinned => _pin != null;
  bool get routeMode => _route != null;

  /// Point mode search centre: the pin wins over the GPS fix. Null in route
  /// mode (the corridor has no single centre).
  LatLng? get searchCenter => _pin ?? _rider;

  /// Centre for per-item distances (list/detail) - null in route mode, where
  /// a distance-from-a-point would mislead.
  LatLng? get distanceCenter => routeMode ? null : searchCenter;

  /// Radius label/ring for the active mode.
  double get activeRadiusKm => routeMode ? routeRadiusKm : pointRadiusKm;

  // ---- data
  bool _loading = false;
  String? _error;
  LatLng? _fetchedAt;
  DateTime? _fetchedTime;

  bool get loading => _loading;
  String? get error => _error;

  String get attribution => _repo.attribution;
  Uri get attributionUrl => _repo.attributionUrl;

  // ---- translation delegates, so call sites keep one surface
  bool get english => translation.english;
  bool get translating => translation.translating;
  List<RoadClosure> get shown => translation.shown;
  TranslatorStatus get translatorStatus => translation.translatorStatus;
  String? get translatorError => translation.translatorError;
  DateTime? get downloadStartedAt => translation.downloadStartedAt;
  ClosureTranslator get translator => translation.translator;
  void toggleLanguage() => translation.toggleLanguage();

  // ---- mutations

  /// New GPS fix. Refreshes (forced on the very first fix so closures load
  /// immediately). The screen still owns camera-follow.
  void setRider(LatLng fix) {
    final first = _rider == null;
    _rider = fix;
    _notify();
    refresh(force: first);
  }

  void dropPin(LatLng where) {
    _pin = where;
    _notify();
    refresh(force: true);
  }

  void clearPin() {
    if (_pin == null) return;
    _pin = null;
    _notify();
    refresh(force: true);
  }

  void loadRoute(List<LatLng> points) {
    _route = points;
    _pin = null; // the route owns the search now
    _notify();
    refresh(force: true);
  }

  void clearRoute() {
    if (_route == null) return;
    _route = null;
    _notify();
    refresh(force: true);
  }

  /// Surface an error from the screen (e.g. a GPX that failed to parse).
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

  /// Refetch when never fetched, the centre moved >10 km from the last fetch,
  /// or the data is older than 15 minutes. A loaded route replaces the point
  /// query with its corridor; only age/force apply (the route is static).
  Future<void> refresh({required bool force}) async {
    final route = _route;
    final center = searchCenter;
    if ((route == null && center == null) || _loading) return;
    final movedKm = route != null || _fetchedAt == null
        ? double.infinity
        : const Distance().as(LengthUnit.Kilometer, _fetchedAt!, center!);
    final age = _fetchedTime == null
        ? const Duration(days: 1)
        : _now().difference(_fetchedTime!);
    if (!force && movedKm < 10 && age < const Duration(minutes: 15)) return;

    _loading = true;
    _error = null;
    _notify();
    // The pulsing disc only renders in point mode; don't run a ticker for
    // an animation nothing shows.
    if (route == null) pulse.repeat(reverse: true);
    try {
      final (all, errors) = route != null
          ? await _repo.fetchAlong(route, routeRadiusKm)
          : await _repo.fetchNear(center!, pointRadiusKm);
      if (center != null) {
        all.sort(
          (a, b) =>
              a.distanceKmFrom(center).compareTo(b.distanceKmFrom(center)),
        );
      }
      _fetchedAt = center;
      _fetchedTime = _now();
      // Partial-source failures: show what we got, but say what's missing.
      _error = errors.isEmpty ? null : errors.join('\n');
      // Hands the list over: originals show immediately, English copies swap
      // in when the (cached, usually instant) translation completes.
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
    }
  }

  @override
  void dispose() {
    _disposed = true;
    translation.removeListener(_notify);
    translation.dispose();
    pulse.dispose();
    super.dispose();
  }
}
