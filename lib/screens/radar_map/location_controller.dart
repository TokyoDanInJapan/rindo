import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

/// The slice of Geolocator that [LocationController] uses. Tests stand in
/// for it without a platform channel.
abstract interface class LocationSource {
  Future<bool> serviceEnabled();
  Future<LocationPermission> checkPermission();
  Future<LocationPermission> requestPermission();
  Future<LatLng?> lastKnown();
  Stream<LatLng> positions();
}

/// [LocationSource] backed by the Geolocator plugin.
class GeolocatorSource implements LocationSource {
  const GeolocatorSource();

  @override
  Future<bool> serviceEnabled() => Geolocator.isLocationServiceEnabled();

  @override
  Future<LocationPermission> checkPermission() => Geolocator.checkPermission();

  @override
  Future<LocationPermission> requestPermission() =>
      Geolocator.requestPermission();

  @override
  Future<LatLng?> lastKnown() async {
    final p = await Geolocator.getLastKnownPosition();
    return p == null ? null : LatLng(p.latitude, p.longitude);
  }

  @override
  Stream<LatLng> positions() => Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 20, // metres between updates
    ),
  ).map((p) => LatLng(p.latitude, p.longitude));
}

/// The rider's GPS fix: permission, the position stream, and its error
/// state. It is extracted from the screen, like the radar and closures
/// controllers, so the recovery paths can be tested.
///
/// It recovers on its own. Location that was refused, switched off, or whose
/// stream died mid-ride is tried again on every [resume], so a rider who
/// fixes it in Settings and comes back does not have to restart the app.
/// While the app is in the background the stream is cancelled, see
/// [suspend], because a high-accuracy fix nobody is looking at costs battery.
class LocationController extends ChangeNotifier {
  LocationController({
    required this.onFix,
    this._source = const GeolocatorSource(),
  });

  /// A new fix: the first from the last known position, then every 20 m.
  final void Function(LatLng) onFix;

  final LocationSource _source;

  StreamSubscription<LatLng>? _sub;
  String? _error;
  bool _starting = false;
  bool _suspended = false;
  bool _disposed = false;

  /// Why there is no fix: a persistent state about permission or the
  /// service, so the banner does not hide itself.
  String? get error => _error;

  /// Whether the position stream is running.
  bool get listening => _sub != null;

  /// Check the service and the permission, then follow the position.
  ///
  /// [ask] requests the permission when it has not been decided. A resume
  /// passes false: a rider who said no should not get the system dialogue
  /// again every time the app comes to the front. Granting it in Settings
  /// still works, because the check sees the new answer.
  Future<void> start({bool ask = true}) async {
    if (_starting || _sub != null || _suspended || _disposed) return;
    _starting = true;
    try {
      if (!await _source.serviceEnabled()) {
        _setError('Location services are disabled');
        return;
      }
      var perm = await _source.checkPermission();
      if (perm == LocationPermission.denied && ask) {
        perm = await _source.requestPermission();
      }
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        _setError('Location permission denied');
        return;
      }
      if (_suspended || _disposed) return;
      _setError(null);

      // A starting point while the first live fix is on its way. Some
      // devices throw here, and that must not stop the live stream below.
      try {
        final last = await _source.lastKnown();
        if (last != null && !_disposed) onFix(last);
      } catch (_) {}
      if (_suspended || _disposed) return;

      _sub = _source.positions().listen(
        onFix,
        onError: (Object e) {
          // The stream is over, for example because the service was switched
          // off mid-ride. The next resume starts a new one.
          _sub = null;
          _setError('Location unavailable: $e');
        },
        cancelOnError: true,
      );
    } catch (e) {
      _setError('Location unavailable: $e');
    } finally {
      _starting = false;
    }
  }

  /// The app went to the background. Stop following the rider.
  void suspend() {
    _suspended = true;
    unawaited(_sub?.cancel());
    _sub = null;
  }

  /// The app is back in front. Follow the rider again, and retry anything
  /// that failed before, without asking for the permission again.
  Future<void> resume() {
    _suspended = false;
    return start(ask: false);
  }

  /// The x on the location banner. It comes back if the next attempt fails.
  void dismissError() => _setError(null);

  void _setError(String? error) {
    if (error == _error || _disposed) return;
    _error = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_sub?.cancel());
    _sub = null;
    super.dispose();
  }
}
