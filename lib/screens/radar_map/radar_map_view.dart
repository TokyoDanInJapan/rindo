import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart';
import 'package:latlong2/latlong.dart';

import '../../jma/jma_api.dart';
import '../../map/japan_outline.g.dart';
import '../../closures/road_closure.dart';
import '../../net/rekey_safe_tile_provider.dart';
import 'closure_presentation.dart';
import 'closures_controller.dart';
import 'disclaimer.dart';
import 'tile_pulse.dart';

/// The full map: prefecture skeleton, base tiles, stacked radar frames, the
/// search overlay (a route track, or a ring and its pulse), closure geometry
/// and markers, the rider and pin markers, and the attribution. It reads the
/// [ClosuresController] for the search area and the closures. The screen owns
/// the camera and the wiring.
class RadarMapView extends StatelessWidget {
  final MapController mapController;
  final ClosuresController closures;

  /// Shared, deadline-guarded client for every tile layer, owned by the
  /// screen (see tile_http_client.dart).
  final Client httpClient;

  final List<JmaFrame> frames;
  final int frameIndex;
  final int tileEpoch;
  final bool greyscale;

  final LatLng initialCenter;
  final double initialZoom;

  /// A gesture pan happened, so the screen breaks camera-follow. (Rotation is
  /// NOT reported from here. MapOptions.onPositionChanged does not fire for
  /// rotation-only changes, so the screen watches the map event stream.)
  final VoidCallback onCameraGesture;
  final void Function(LatLng) onLongPress;

  /// A tap on the rider dot or the scouting pin. The screen then offers the
  /// weather there, and for the pin it also offers to clear the pin.
  final void Function(LatLng point, {required bool pinned}) onShowPlace;

  final void Function(RoadClosure) onShowDetail;
  final void Function(Uri) onOpenUrl;

  /// Tile failure hook, labelled 'base' or 'radar' so that the expected radar
  /// 404s can be told apart from real failures.
  final void Function(String layer, TileImage, Object, StackTrace?) onTileError;

  /// Retry everything (the screen bumps the tile epoch). Wired to taps on
  /// the broken-tile placeholders.
  final VoidCallback onRetryTiles;

  const RadarMapView({
    super.key,
    required this.mapController,
    required this.closures,
    required this.httpClient,
    required this.frames,
    required this.frameIndex,
    required this.tileEpoch,
    required this.greyscale,
    required this.initialCenter,
    required this.initialZoom,
    required this.onCameraGesture,
    required this.onLongPress,
    required this.onShowPlace,
    required this.onShowDetail,
    required this.onOpenUrl,
    required this.onTileError,
    required this.onRetryTiles,
  });

  static const _userAgent = 'com.hebberd.rindo';

  /// How long the camera must hold still before the tiles react to it. A
  /// gesture emits camera events every frame, and reacting to each one fetches
  /// tiles for camera states that are gone a frame later. On a marginal mobile
  /// link that mid-gesture burst is what floods the connection, see
  /// tile_http_client.dart. Debouncing fetches once, for the camera the user
  /// actually settles on. GPS follow-mode moves are discrete, about one a
  /// second, which is well over this delay, so riding along still loads
  /// promptly.
  static const _settleDelay = Duration(milliseconds: 250);

  static const _cyclosmUrl =
      'https://{s}.tile-cyclosm.openstreetmap.fr/cyclosm/{z}/{x}/{y}.png';
  // English-labelled world base map from Esri. Note the {y}/{x} order.
  static const _esriUrl =
      'https://server.arcgisonline.com/ArcGIS/rest/services/'
      'World_Street_Map/MapServer/tile/{z}/{y}/{x}';

  static const _greyscaleMatrix = <double>[
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0.2126, 0.7152, 0.0722, 0, 0, //
    0, 0, 0, 1, 0,
  ];

  // Built once, because the prefecture rings never change.
  static final _outline = [
    for (final ring in japanOutline)
      Polyline(
        points: ring,
        color: Colors.blueGrey.withValues(alpha: 0.55),
        strokeWidth: 1,
      ),
  ];

  // Explicit provider for every tile layer. This controls the client and,
  // crucially, disables flutter_map 8's process-wide built-in cache singleton.
  // That singleton is the one piece of the base-tile path that a tile-epoch
  // re-key cannot reset, so a bad state in it survives every in-app retry and
  // clears only on a full restart. Live radar does not need cross-session tile
  // caching anyway. It is cheap to build on every rebuild, because the client
  // is injected: no client is created, and layer disposal does not close it.
  //
  // RekeySafeTileProvider handles the *other* process-wide cache in the tile
  // path, Flutter's own image cache, where a re-key would otherwise leave
  // every in-flight tile permanently blank. See that file.
  TileProvider _tileProvider() => RekeySafeTileProvider(
    httpClient: httpClient,
    cachingProvider: const DisabledMapCachingProvider(),
  );

  @override
  Widget build(BuildContext context) {
    final frame = frames.isEmpty ? null : frames[frameIndex];
    return FlutterMap(
      mapController: mapController,
      options: MapOptions(
        initialCenter: initialCenter,
        initialZoom: initialZoom,
        minZoom: 5,
        maxZoom: 17,
        onPositionChanged: (camera, hasGesture) {
          if (hasGesture) onCameraGesture();
        },
        // Long-press drops a scouting pin. Closures then load around the pin
        // instead of around the GPS fix. Tap the pin or the locate button to
        // go back.
        onLongPress: (_, latLng) => onLongPress(latLng),
      ),
      children: [
        ..._baseAndRadar(frame),
        ..._searchOverlay(),
        ..._closureLayers(),
        _attribution(context),
      ],
    );
  }

  /// Base-map tile chrome: a pulse while the image is on its way, and a
  /// visible, tappable 'broken tile' placeholder when it failed. A blank spot
  /// is then diagnosable, as loading or as failed, and recoverable in place.
  /// The greyscale filter is applied here, per tile, rather than around the
  /// whole layer. ColorFiltered's saveLayer bounds miss parts of the
  /// camera-transformed layer, which leaves unfiltered strips.
  Widget _pulsingTile(BuildContext context, Widget tile, TileImage image) {
    if (image.loadError) {
      return GestureDetector(
        onTap: onRetryTiles,
        child: Container(
          decoration: BoxDecoration(
            color: Colors.blueGrey.withValues(alpha: 0.10),
            border: Border.all(
              color: Colors.blueGrey.withValues(alpha: 0.25),
              width: 0.5,
            ),
          ),
          child: Center(
            child: Icon(
              Icons.refresh,
              size: 22,
              color: Colors.blueGrey.withValues(alpha: 0.55),
            ),
          ),
        ),
      );
    }
    final t = greyscale
        ? ColorFiltered(
            colorFilter: const ColorFilter.matrix(_greyscaleMatrix),
            child: tile,
          )
        : tile;
    if (image.loadFinishedAt != null) return t;
    return Stack(fit: StackFit.expand, children: [const TilePulse(), t]);
  }

  /// Prefecture skeleton below the tiles, the base map, and the stacked radar
  /// frames. Only the active frame is visible.
  List<Widget> _baseAndRadar(JmaFrame? frame) => [
    // The skeleton sits BELOW the tile layers, so it shows only where opaque
    // map tiles have not painted yet, either still loading or unreachable
    // offline. It disappears as those tiles arrive.
    PolylineLayer(polylines: _outline),
    TileLayer(
      key: ValueKey('base-$tileEpoch-${closures.english}'),
      urlTemplate: closures.english ? _esriUrl : _cyclosmUrl,
      tileProvider: _tileProvider(),
      // Only used where the template has an {s} (CyclOSM).
      subdomains: const ['a', 'b', 'c'],
      userAgentPackageName: _userAgent,
      maxNativeZoom: 19,
      // A fresh instance per layer. These transformers hold per-stream timer
      // state, so a shared static would cross-wire the layers' debounce
      // clocks.
      tileUpdateTransformer: TileUpdateTransformers.debounce(_settleDelay),
      errorTileCallback: (t, e, st) => onTileError('base', t, e, st),
      // Base map only: the radar layers are transparent overlays, where a
      // pulse would paint grey over perfectly loaded map.
      tileBuilder: _pulsingTile,
    ),
    // All frames stay mounted so that their tiles pre-load and the animation
    // never flickers. Only the active frame is visible. A 404 from JMA means
    // 'no rain in this tile' and simply renders as nothing.
    _RadarFrameLayers(view: this, active: frame),
  ];

  /// The loaded GPX track. In point mode, the search ring plus its loading
  /// pulse instead.
  List<Widget> _searchOverlay() {
    final route = closures.route;
    if (route != null) {
      return [
        PolylineLayer(
          polylines: [
            Polyline(
              points: route,
              color: Colors.deepPurple.withValues(alpha: 0.75),
              strokeWidth: 4,
            ),
          ],
        ),
      ];
    }
    final center = closures.searchCenter;
    if (center == null) return const [];
    final ringColor = closures.pinned ? Colors.teal : Colors.blueGrey;
    const radiusM = ClosuresController.pointRadiusKm * 1000;
    return [
      CircleLayer(
        circles: [
          CircleMarker(
            point: center,
            radius: radiusM,
            useRadiusInMeter: true,
            color: Colors.transparent,
            borderColor: ringColor.withValues(alpha: 0.45),
            borderStrokeWidth: closures.pinned ? 2.5 : 1.5,
          ),
        ],
      ),
      // While closures for the area are loading, the disc pulses.
      FadeTransition(
        opacity: Tween(begin: 0.0, end: 0.15).animate(
          CurvedAnimation(parent: closures.pulse, curve: Curves.easeInOut),
        ),
        child: CircleLayer(
          circles: [
            CircleMarker(
              point: center,
              radius: radiusM,
              useRadiusInMeter: true,
              color: ringColor,
            ),
          ],
        ),
      ),
    ];
  }

  /// Regulated road segments, closure markers, and the rider and pin markers.
  List<Widget> _closureLayers() {
    final now = DateTime.now();
    final shown = closures.shown;
    final rider = closures.rider;
    final pin = closures.pin;
    return [
      PolylineLayer(
        polylines: [
          for (final c in shown)
            for (final line in c.lines)
              if (line.length >= 2)
                Polyline(
                  points: line,
                  color: closureColor(c, now).withValues(alpha: 0.8),
                  strokeWidth: 5,
                ),
        ],
      ),
      MarkerLayer(
        markers: [
          for (final c in shown)
            Marker(
              point: c.point,
              width: 36,
              height: 36,
              child: GestureDetector(
                onTap: () => onShowDetail(c),
                child: Icon(
                  closureIcon(c),
                  color: closureColor(c, now),
                  size: c.isFullClosure ? 30 : 28,
                  shadows: const [Shadow(blurRadius: 4, color: Colors.white)],
                ),
              ),
            ),
          if (rider != null)
            Marker(
              point: rider,
              // Twice the dot's size. The visible dot stays 22 px, because it
              // marks a position and a bigger one would claim precision the
              // fix does not have. But a 22 px tap target on a moving bike is
              // no target at all, so the transparent surround takes the tap.
              width: 44,
              height: 44,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onShowPlace(rider, pinned: false),
                child: Center(
                  child: SizedBox(
                    width: 22,
                    height: 22,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.blue.shade600,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: const [BoxShadow(blurRadius: 6)],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          if (pin != null)
            Marker(
              point: pin,
              width: 44,
              height: 44,
              // Bottom tip of the glyph sits on the pinned spot.
              alignment: Alignment.topCenter,
              child: GestureDetector(
                onTap: () => onShowPlace(pin, pinned: true),
                child: Icon(
                  Icons.place,
                  color: Colors.teal.shade700,
                  size: 44,
                  shadows: const [Shadow(blurRadius: 4, color: Colors.white)],
                ),
              ),
            ),
        ],
      ),
    ];
  }

  /// The mandatory data credits: the standard low-key (i) in the corner, which
  /// opens a *centred* dialogue. flutter_map's RichAttributionWidget is not
  /// used, because its panel expands from the corner it lives in and slides
  /// underneath the button stack. A dialogue floats clear of everything. The
  /// styling mirrors that widget's collapsed state: a half-opacity info icon,
  /// inside SafeArea.
  Widget _attribution(BuildContext context) => SafeArea(
    child: Align(
      alignment: Alignment.bottomRight,
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Opacity(
          opacity: 0.5,
          child: IconButton(
            tooltip: 'Map credits',
            icon: const Icon(Icons.info_outlined),
            onPressed: () => _showAttribution(context),
          ),
        ),
      ),
    ),
  );

  void _showAttribution(BuildContext context) {
    final entries = [
      (
        'JMA Weather (processed)',
        Uri.parse('https://www.jma.go.jp/jma/en/copyright.html'),
      ),
      (
        '© OpenStreetMap contributors',
        Uri.parse('https://www.openstreetmap.org/copyright'),
      ),
      if (closures.english)
        (
          // Esri's terms want the data providers credited, not just the
          // product. This is their standard string for World Street Map.
          'Esri - World Street Map. Sources: Esri, TomTom, Garmin, FAO, '
              'NOAA, USGS, © OpenStreetMap contributors, and the GIS User '
              'Community',
          Uri.parse(
            'https://www.esri.com/en-us/legal/terms/full-master-agreement',
          ),
        )
      else
        // OSM France donates the tile hosting. Their usage policy asks for
        // the hosting to be credited alongside the style.
        (
          'CyclOSM · tiles hosted by OpenStreetMap France',
          Uri.parse('https://www.cyclosm.org'),
        ),
      (closures.attribution, closures.attributionUrl),
    ];
    showDialog<void>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Map data'),
        children: [
          for (final (label, url) in entries)
            SimpleDialogOption(
              onPressed: () => onOpenUrl(url),
              child: Text(label),
            ),
          const Divider(),
          // Same warning the rider acknowledged at first launch, kept
          // permanently readable here.
          Padding(
            // Matches SimpleDialogOption's horizontal inset.
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(
              disclaimerText,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// The stacked radar frame layers, fetching at a *settled* JMA zoom.
///
/// JMA renders only even zooms, because odd levels come back as blank 200s.
/// See jma_api.dart. Each layer therefore pins its fetch to [jmaNativeZoom]
/// and scales the tiles to the camera. Changing that level means re-keying the
/// layers, which refetches every frame's whole grid. Doing that live while a
/// pinch sweeps z10→z6 would fire hundreds of requests for levels the gesture
/// leaves behind a moment later. The switch waits instead until the zoom has
/// held still for [RadarMapView._settleDelay]. Until then the current grid
/// keeps rendering, scaled by at most 2× per level: briefly blockier, never
/// blank.
class _RadarFrameLayers extends StatefulWidget {
  const _RadarFrameLayers({required this.view, required this.active});

  final RadarMapView view;
  final JmaFrame? active;

  @override
  State<_RadarFrameLayers> createState() => _RadarFrameLayersState();
}

class _RadarFrameLayersState extends State<_RadarFrameLayers> {
  /// Pace of the staged frame mounting below. The next preload frame joins
  /// only after the previous one has had this long to drain its grid through
  /// the per-host connection queue.
  static const _preloadInterval = Duration(milliseconds: 1500);

  int? _native; // level the layers are keyed to (null until first build)
  double? _lastZoom;
  Timer? _settle;

  // Staged mounting state: which frames are mounted in the current
  // generation. A generation is one combination of epoch, level and frame set.
  final _mountedFrames = <String>{};
  String _generation = '';
  Timer? _preload;
  // The settle clock ran out, so the next build applies the level the camera
  // is *then* on. The timer deliberately carries no level itself. If the
  // camera slips back across the boundary just as the clock fires, a captured
  // value would re-key to a level the camera has already left.
  bool _settleElapsed = false;

  void _cancelSettle() {
    _settle?.cancel();
    _settle = null;
    _settleElapsed = false;
  }

  @override
  void dispose() {
    _settle?.cancel();
    _preload?.cancel();
    super.dispose();
  }

  /// Mount the next frame that is not mounted yet. Stop the timer once every
  /// frame is in.
  void _mountNextFrame() {
    if (!mounted) return;
    final frames = widget.view.frames;
    JmaFrame? next;
    for (final f in frames) {
      if (!_mountedFrames.contains(f.urlTemplate)) {
        next = f;
        break;
      }
    }
    if (next == null) {
      _preload?.cancel();
      _preload = null;
      return;
    }
    setState(() => _mountedFrames.add(next!.urlTemplate));
    if (frames.every((f) => _mountedFrames.contains(f.urlTemplate))) {
      _preload?.cancel();
      _preload = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // MapCamera.of registers a dependency, so this rebuilds as the camera
    // moves and the settle logic below sees every zoom change.
    final zoom = MapCamera.of(context).zoom;
    final target = jmaNativeZoom(zoom);
    if (_native == null) {
      _native = target; // first build: nothing to settle from
    } else if (target == _native) {
      // Back on the level already shown, or never left it. Drop any pending
      // switch from a crossing that the gesture reversed out of.
      _cancelSettle();
    } else if (_settleElapsed) {
      _native = target; // the zoom held still long enough, so switch now
      _settleElapsed = false;
    } else if (zoom != _lastZoom || _settle == null) {
      // The zoom moved towards another level, so start the settle clock
      // again. A rebuild *without* a zoom change keeps the pending timer
      // rather than pushing the switch out forever. Such a rebuild comes from
      // a parent setState, because the asset monitor repaints constantly.
      _settle?.cancel();
      _settle = Timer(RadarMapView._settleDelay, () {
        _settle = null;
        _settleElapsed = true;
        if (mounted) setState(() {});
      });
    }
    _lastZoom = zoom;

    final v = widget.view;
    // Staged mounting. A re-key, from an epoch bump, a level switch or a new
    // frame set, makes every mounted frame refetch its whole grid at once.
    // That is six frames' worth of tiles racing through the per-host
    // connection queue, with the *visible* frame's tiles stuck behind five
    // invisible preloads. Queue wait counts against the request deadline, see
    // tile_http_client.dart, so at wide viewports that flood timed the whole
    // radar out. Each generation therefore mounts the active frame first,
    // which puts rain on screen in seconds, and adds the others one at a time
    // for flicker-free playback. The set only grows within a generation, so
    // playback that moves the active frame never unmounts a layer that is
    // already fetching, and so never cancels one.
    final gen =
        '${v.tileEpoch}-z$_native-'
        '${v.frames.isEmpty ? '' : v.frames.first.urlTemplate}';
    if (gen != _generation) {
      _generation = gen;
      _mountedFrames.clear();
      _preload?.cancel();
      _preload = v.frames.length > 1
          ? Timer.periodic(_preloadInterval, (_) => _mountNextFrame())
          : null;
    }
    final active = widget.active;
    if (active != null) _mountedFrames.add(active.urlTemplate);

    // A plain Stack mirrors how FlutterMap lays out its own children, so
    // nesting the layers here changes nothing about their sizing.
    return Stack(
      children: [
        for (final f in v.frames)
          if (_mountedFrames.contains(f.urlTemplate))
            Opacity(
              opacity: identical(f, widget.active) ? 0.7 : 0.0,
              child: TileLayer(
                key: ValueKey('${f.urlTemplate}-${v.tileEpoch}-z$_native'),
                urlTemplate: f.urlTemplate,
                tileProvider: v._tileProvider(),
                userAgentPackageName: RadarMapView._userAgent,
                minNativeZoom: _native!,
                maxNativeZoom: _native!,
                // A fresh instance per layer, see the base layer's note.
                tileUpdateTransformer: TileUpdateTransformers.debounce(
                  RadarMapView._settleDelay,
                ),
                // Rain-free tiles 404, which is expected. The monitor filters
                // those out.
                errorTileCallback: (t, e, st) =>
                    v.onTileError('radar', t, e, st),
              ),
            ),
      ],
    );
  }
}
