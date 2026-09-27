import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:rindo/screens/radar_map/location_controller.dart';

/// Pins the location recovery paths that used to live untested in the
/// screen: a refused permission or a dead stream recovers on resume, a
/// resume never nags with the system dialogue, and the background stops the
/// stream.

class _FakeSource implements LocationSource {
  bool enabled = true;
  LocationPermission permission = LocationPermission.whileInUse;
  LocationPermission answer = LocationPermission.whileInUse;
  LatLng? last;
  int requests = 0;
  int streams = 0;
  StreamController<LatLng>? stream;

  @override
  Future<bool> serviceEnabled() async => enabled;

  @override
  Future<LocationPermission> checkPermission() async => permission;

  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return permission = answer;
  }

  @override
  Future<LatLng?> lastKnown() async => last;

  Future<void> close() async => stream?.close();

  @override
  Stream<LatLng> positions() {
    streams++;
    stream = StreamController<LatLng>();
    return stream!.stream;
  }
}

void main() {
  late _FakeSource source;
  late List<LatLng> fixes;
  late LocationController c;

  setUp(() {
    source = _FakeSource();
    fixes = [];
    c = LocationController(onFix: fixes.add, source: source);
  });

  tearDown(() async {
    c.dispose();
    await source.close();
  });

  test('a granted start reports the last known fix, then live ones', () async {
    source.last = const LatLng(35, 139);
    await c.start();
    expect(c.error, isNull);
    expect(c.listening, isTrue);
    source.stream!.add(const LatLng(35.1, 139));
    await pumpEventQueue();
    expect(fixes, [const LatLng(35, 139), const LatLng(35.1, 139)]);
  });

  test('a refusal recovers on resume once granted in Settings, without '
      'asking again', () async {
    source.permission = LocationPermission.denied;
    source.answer = LocationPermission.denied;
    await c.start();
    expect(c.error, 'Location permission denied');
    expect(source.requests, 1);

    // Still refused: the resume checks, but does not raise the dialogue.
    await c.resume();
    expect(source.requests, 1);
    expect(c.error, 'Location permission denied');

    // Granted in Settings, then back to the app.
    source.permission = LocationPermission.whileInUse;
    await c.resume();
    expect(c.error, isNull);
    expect(c.listening, isTrue);
  });

  test('services switched off mid-ride end the stream; the next resume '
      'starts a new one', () async {
    await c.start();
    source.stream!.addError(const LocationServiceDisabledException());
    await pumpEventQueue();
    expect(c.listening, isFalse);
    expect(c.error, contains('Location unavailable'));

    await c.resume();
    expect(source.streams, 2);
    expect(c.listening, isTrue);
    expect(c.error, isNull);
  });

  test('suspend stops the stream, and resume restarts it', () async {
    await c.start();
    c.suspend();
    expect(c.listening, isFalse);
    // A start while suspended does nothing: the app is in the background.
    await c.start();
    expect(source.streams, 1);
    await c.resume();
    expect(source.streams, 2);
  });

  test('a throwing plugin becomes an error, not an unhandled exception', () {
    final broken = LocationController(onFix: fixes.add, source: _Throwing());
    addTearDown(broken.dispose);
    expect(broken.start(), completes);
  });
}

class _Throwing extends _FakeSource {
  @override
  Future<LocationPermission> checkPermission() =>
      Future.error(const PermissionDefinitionsNotFoundException('no manifest'));
}
