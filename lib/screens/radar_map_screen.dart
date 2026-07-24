import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' show Client;
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../closures/closure_repository.dart';
import '../closures/road_closure.dart';
import '../jma/jma_api.dart';
import '../route/gpx_route.dart';
import '../net/asset_monitor.dart';
import '../net/connectivity_monitor.dart';
import 'radar_map/closure_sheets.dart';
import 'radar_map/debug_sheet.dart';
import 'radar_map/disclaimer.dart';
import 'radar_map/closures_controller.dart';
import 'radar_map/frame_controls.dart';
import 'radar_map/map_banners.dart';
import 'radar_map/map_compass.dart';
import 'radar_map/map_fab_stack.dart';
import 'radar_map/radar_frame_controller.dart';
import 'radar_map/radar_legend.dart';
import 'radar_map/radar_map_view.dart';
import '../net/tile_http_client.dart';
import '../net/tile_status.dart';

/// Rider-centred rain radar over a CyclOSM cycling base map, with nearby
/// road closures overlaid. One screen, plain setState; the widgets live in
/// `radar_map/`, this file owns the state and the layer stack.
class RadarMapScreen extends StatefulWidget {
  const RadarMapScreen({super.key});

  @override
  State<RadarMapScreen> createState() => _RadarMapScreenState();
}

class _RadarMapScreenState extends State<RadarMapScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  static const _fallbackCenter = LatLng(35.681, 139.767); // Tokyo Station
  static const _initialZoom = 10.0;
  // A transient closures error banner auto-hides after this.
  static const _errorLinger = Duration(seconds: 8);

  final _mapController = MapController();

  // Every HTTP fetch - tiles, JMA indexes, closures feeds - reports its
  // lifecycle here, so the debug sheet can show what's in flight, what
  // failed at which zoom, and why.
  final _assets = AssetMonitor();

  // One shared, deadline-guarded client for every tile layer (base + radar).
  // Injected so flutter_map doesn't close it when a layer re-keys; we own its
  // lifecycle. The deadline is what stops a stalled tile from hanging forever
  // (see tile_http_client.dart).
  late final _tileClient = MonitoredClient(tileHttpClient(), _assets);

  // Shared client for the JSON/XML feeds (JMA targetTimes, closures sources).
  late final _apiClient = MonitoredClient(Client(), _assets);

  late final _jma = JmaApi(client: _apiClient);

  // Closures, translation, and the search area (rider/pin/route) all live in
  // the controller; the screen just drives the camera and reads its getters.
  late final ClosuresController _closures = ClosuresController(
    vsync: this,
    repository: ClosureRepository(client: _apiClient),
  );

  // Greyscale base map by default (like JMA's own nowcast page) so radar and
  // closures pop; the map view applies the filter, the FAB toggles this.
  bool _greyscale = true;

  // Offline heuristic, tile epoch, banner-dismissed state, cold-start grace.
  final _connectivity = ConnectivityMonitor();

  // Radar frames: the list + refresh cycle, playback, error linger, and the
  // fast-reconnect backoff. On success the monitor heals (re-keying tiles if
  // there was an outage); on a frame-set swap the per-tile bookkeeping resets
  // so stale failures don't pin the banner.
  late final RadarFrameController _radar = RadarFrameController(
    loadFrames: _jma.getFrames,
    onLoaded: () {
      if (_connectivity.heal()) {
        _tileStatus.reset();
        _assets.resetRadarFrames();
      }
    },
    onFramesReplaced: () {
      _tileStatus.reset();
      _assets.resetRadarFrames();
    },
    onReconnect: () => _closures.refresh(force: false),
  );

  // Camera-follow: on by default, disengaged by a manual pan or a pin/route.
  bool _follow = true;
  String? _locationError;
  StreamSubscription<Position>? _posSub;

  // Current map bearing (degrees, 0 == north-up). Drives the compass button,
  // which only appears when the map is turned off north. Fed by the map
  // event stream, NOT MapOptions.onPositionChanged: flutter_map only fires
  // that for moves - a rotation-only change (the compass tap, a clean
  // two-finger twist) never reaches it, which left the needle frozen.
  // A ValueNotifier (not setState) so only the compass repaints.
  final _rotation = ValueNotifier<double>(0);
  StreamSubscription<MapEvent>? _mapEvents;

  // Auto-dismiss timer for the transient closures error banner. (Location
  // errors are persistent states - permission/service - so they don't
  // auto-hide.)
  Timer? _closuresErrorTimer;
  String? _lastClosuresError;

  // Failed-tile bookkeeping for the "N tiles failed - tap to retry" banner
  // and the per-tile broken placeholders.
  final _tileStatus = TileStatusMonitor();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Repaint on any closures/translation/search-area change.
    _closures.addListener(_onClosuresChanged);
    // Frames/index/epoch/offline all drive the map stack itself, so these
    // repaint the whole screen. (The 5 Hz asset chatter and per-tile failure
    // counts deliberately do NOT - their consumers rebuild themselves via
    // scoped ListenableBuilders in build().)
    _radar.addListener(_repaint);
    _connectivity.addListener(_repaint);
    _mapEvents = _mapController.mapEventStream.listen(
      (e) => _rotation.value = e.camera.rotation,
    );
    _radar.start();
    _initLocation();
    // First launch only: the data-limits warning, before the map is usable.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => showFirstRunDisclaimer(context),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _closuresErrorTimer?.cancel();
    _mapEvents?.cancel();
    _posSub?.cancel();
    _radar.dispose();
    _connectivity.dispose();
    _rotation.dispose();
    _tileStatus.dispose();
    _closures.dispose();
    _mapController.dispose();
    _tileClient.close();
    _apiClient.close();
    _assets.dispose();
    super.dispose();
  }

  void _repaint() {
    if (mounted) setState(() {});
  }

  void _onClosuresChanged() {
    if (!mounted) return;
    // Auto-hide a freshly-raised closures error after a few seconds; a later
    // failed fetch raises a new one and re-arms this.
    final err = _closures.error;
    if (err != null && err != _lastClosuresError) {
      _closuresErrorTimer?.cancel();
      _closuresErrorTimer = Timer(_errorLinger, () {
        if (mounted) _closures.dismissError();
      });
    }
    _lastClosuresError = err;
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _radar.load();
      _closures.refresh(force: false);
    }
  }

  // ------------------------------------------------------------- location

  Future<void> _initLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      setState(() => _locationError = 'Location services are disabled');
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      setState(() => _locationError = 'Location permission denied');
      return;
    }
    setState(() => _locationError = null);

    final last = await Geolocator.getLastKnownPosition();
    if (last != null) _onFix(LatLng(last.latitude, last.longitude));

    _posSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 20, // metres between updates
          ),
        ).listen(
          (p) => _onFix(LatLng(p.latitude, p.longitude)),
          onError: (e) => setState(() => _locationError = '$e'),
        );
  }

  void _onFix(LatLng fix) {
    final first = _closures.rider == null;
    _closures.setRider(fix); // updates the search area + refreshes closures
    if (_follow || first) {
      _mapController.move(
        fix,
        first ? _initialZoom : _mapController.camera.zoom,
      );
    }
  }

  // ------------------------------------------------------------- GPX route

  /// FAB action: pick a .gpx to scout, or clear the loaded one.
  Future<void> _pickOrClearRoute() async {
    if (_closures.routeMode) {
      _closures.clearRoute();
      return;
    }
    try {
      // No extension filter: Android greys .gpx out under one because the
      // MIME type is unregistered. copyFileToCacheDir gives a readable path
      // even for cloud/Downloads content: URIs.
      final path = await FlutterFileDialog.pickFile(
        params: const OpenFileDialogParams(copyFileToCacheDir: true),
      );
      if (path == null) return; // cancelled
      final file = File(path);
      final content = await file.readAsString();
      // The picker copied the file into our cache dir; parsed, it's garbage -
      // without this, every picked route accumulates there.
      try {
        await file.delete();
      } catch (_) {}
      final route = parseGpx(content);
      setState(() => _follow = false); // route owns the view now
      _closures.loadRoute(route);
      _mapController.fitCamera(
        CameraFit.coordinates(
          coordinates: thinRoute(route, 1),
          padding: const EdgeInsets.fromLTRB(48, 240, 48, 140),
        ),
      );
    } catch (e) {
      if (mounted) {
        _closures.reportError('GPX: $e');
      }
    }
  }

  // --------------------------------------------------------- connectivity

  /// Retry every failed tile: re-key the layers and clear the bookkeeping.
  void _retryTiles() {
    _tileStatus.reset();
    _assets.resetRadarFrames();
    _connectivity.bumpEpoch();
  }

  /// Compass tap: turn the map back to north-up. onRotationChanged then clears
  /// _rotation, which hides the compass.
  void _faceNorth() => _mapController.rotate(0);

  /// Tile-layer error hook. JMA 404s (rain-free tiles) are filtered by the
  /// monitor; socket-level failures additionally drive the offline banner.
  void _onTileError(
    String layer,
    TileImage tile,
    Object error,
    StackTrace? stackTrace,
  ) {
    _tileStatus.recordError(layer, tile.coordinates, error);
    _connectivity.recordTileError(error);
  }

  /// The × on an error banner: clear that error's source so it stays hidden
  /// until the condition recurs. (Offline keeps its recovery state - only the
  /// banner is suppressed - so tiles still refetch when the network returns.)
  void _dismissBanner(MapBanner banner) {
    switch (banner) {
      case MapBanner.offline:
        _connectivity.dismissOffline();
      case MapBanner.tiles:
        _tileStatus.reset();
      case MapBanner.radar:
        _radar.dismissError();
      case MapBanner.location:
        setState(() => _locationError = null);
      case MapBanner.closures:
        _closures.dismissError();
    }
  }

  // ------------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          RadarMapView(
            mapController: _mapController,
            closures: _closures,
            httpClient: _tileClient,
            frames: _radar.frames,
            frameIndex: _radar.frameIndex,
            tileEpoch: _connectivity.tileEpoch,
            greyscale: _greyscale,
            initialCenter: _closures.rider ?? _fallbackCenter,
            initialZoom: _initialZoom,
            onCameraGesture: () {
              // A manual pan breaks follow mode until the FAB re-enables it.
              if (_follow) setState(() => _follow = false);
            },
            onLongPress: (latLng) {
              _closures.dropPin(latLng);
              setState(() => _follow = false);
            },
            onShowDetail: _showDetail,
            onOpenUrl: _open,
            onTileError: _onTileError,
            onRetryTiles: _retryTiles,
          ),
          SafeArea(
            child: Column(
              children: [
                // Rebuilds as tile fetches land (the per-frame load dots) -
                // scoped here so the ~5 Hz asset chatter doesn't repaint the
                // whole map stack.
                ListenableBuilder(
                  listenable: _assets,
                  builder: (context, _) => FrameControls(
                    frames: _radar.frames,
                    frameIndex: _radar.frameIndex,
                    frameStatus: _frameStatuses(),
                    playing: _radar.playing,
                    onPlayPause: _radar.togglePlay,
                    onSeek: _radar.seek,
                  ),
                ),
                // Rebuilds per failed-tile count change, scoped for the same
                // reason as the frame strip above.
                ListenableBuilder(
                  listenable: _tileStatus,
                  builder: (context, _) => MapBanners(
                    // Hold the connectivity banners during the cold-start
                    // grace so a momentary launch gap doesn't flash before
                    // the first retry lands. Informational banners
                    // (translation) still show.
                    offline:
                        _connectivity.pastStartupGrace &&
                        _connectivity.isOffline,
                    offlineDismissed: _connectivity.offlineDismissed,
                    english: _closures.english,
                    translatorStatus: _closures.translatorStatus,
                    translatorError: _closures.translatorError,
                    downloadStartedAt: _closures.downloadStartedAt,
                    translating: _closures.translating,
                    radarError: _connectivity.pastStartupGrace
                        ? _radar.radarError
                        : null,
                    locationError: _locationError,
                    closuresError: _connectivity.pastStartupGrace
                        ? _closures.error
                        : null,
                    failedTileCount: _connectivity.pastStartupGrace
                        ? _tileStatus.failedCount
                        : 0,
                    onRetryTiles: _retryTiles,
                    onDismiss: _dismissBanner,
                  ),
                ),
                ValueListenableBuilder<double>(
                  valueListenable: _rotation,
                  builder: (context, deg, _) =>
                      MapCompass(rotationDeg: deg, onFaceNorth: _faceNorth),
                ),
                const Spacer(),
                const Align(
                  alignment: Alignment.bottomLeft,
                  child: RadarLegend(),
                ),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: MapFabStack(
        routeLoaded: _closures.routeMode,
        english: _closures.english,
        greyscale: _greyscale,
        closureCount: _closures.shown.length,
        closuresLoading: _closures.loading,
        pinned: _closures.pinned,
        following: _follow,
        onShowDebug: _showDebug,
        onToggleRoute: _pickOrClearRoute,
        onToggleLanguage: _closures.toggleLanguage,
        onToggleGreyscale: () => setState(() => _greyscale = !_greyscale),
        onShowClosures: _showList,
        onRefresh: () {
          // Re-key the tile layers too: retries any tiles that errored
          // (flutter_map won't by itself).
          _retryTiles();
          _radar.load();
          _closures.refresh(force: true);
        },
        onRecenter: () {
          _closures.clearPin();
          setState(() => _follow = true);
          final r = _closures.rider;
          if (r != null) _mapController.move(r, _mapController.camera.zoom);
        },
      ),
    );
  }

  /// The even level the radar layers are pinned to right now (see
  /// jmaNativeZoom); falls back to the initial zoom before first layout.
  int get _radarNativeZoom {
    double zoom;
    try {
      zoom = _mapController.camera.zoom;
    } catch (_) {
      zoom = _initialZoom;
    }
    return jmaNativeZoom(zoom);
  }

  /// Per-frame load dots for the frame strip, at the current native zoom.
  List<FrameLoadState> _frameStatuses() {
    final z = _radarNativeZoom;
    return [for (final f in _radar.frames) _assets.frameState(f.validtime, z)];
  }

  void _showDebug() =>
      showAssetDebugSheet(context, monitor: _assets, snapshot: _debugState);

  /// Fresh snapshot for the debug sheet; called on each of its repaints.
  DebugScreenState _debugState() {
    MapCamera? cam;
    try {
      cam = _mapController.camera;
    } catch (_) {} // map not laid out yet
    return DebugScreenState(
      cameraZoom: cam?.zoom,
      cameraCenter: cam == null
          ? null
          : '${cam.center.latitude.toStringAsFixed(3)}, '
                '${cam.center.longitude.toStringAsFixed(3)}',
      offline: _connectivity.isOffline,
      pastStartupGrace: _connectivity.pastStartupGrace,
      offlineDismissed: _connectivity.offlineDismissed,
      tileEpoch: _connectivity.tileEpoch,
      reconnectAttempt: _radar.reconnectAttempt,
      failedTileCount: _tileStatus.failedCount,
      lastTileError: _tileStatus.lastError,
      frames: _radar.frames,
      frameIndex: _radar.frameIndex,
      radarNativeZoom: _radarNativeZoom,
      radarError: _radar.radarError,
      hasFix: _closures.rider != null,
      locationError: _locationError,
      closureCount: _closures.shown.length,
      closuresLoading: _closures.loading,
      closuresError: _closures.error,
      translatorStatus: _closures.translatorStatus.name,
      translating: _closures.translating,
    );
  }

  void _showList() => showClosureList(
    context,
    closures: _closures.shown,
    center: _closures.distanceCenter,
    pinned: _closures.pinned,
    routeMode: _closures.routeMode,
    loading: _closures.loading,
    radiusKm: _closures.activeRadiusKm,
    attribution: _closures.attribution,
    onSelect: (c) {
      _mapController.move(c.point, 12);
      setState(() => _follow = false);
      _showDetail(c);
    },
  );

  void _showDetail(RoadClosure c) => showClosureDetail(
    context,
    c,
    center: _closures.distanceCenter,
    pinned: _closures.pinned,
    onOpenSource: _open,
  );

  Future<void> _open(Uri url) async {
    await launchUrl(url, mode: LaunchMode.externalApplication);
  }
}
