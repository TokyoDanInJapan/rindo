import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';

/// Tile provider that survives a tile-layer re-key.
///
/// Flutter's process-wide `PaintingBinding.instance.imageCache` keys entries by
/// tile URL. [ImageCache.putIfAbsent] hands out the completer of an entry that
/// is still *in flight* rather than starting a second fetch. Two [TileImage]s
/// for the same URL therefore share one load. That is normally exactly what you
/// want, but it is a disaster in one specific case:
///
/// Re-keying a `TileLayer` mounts the replacement layer *before* Flutter
/// unmounts the old one. A re-key happens on the tile-epoch bump, a radar
/// native-zoom switch, a frame-set swap and the base-map language toggle.
/// `didChangeDependencies` on the new element runs in the same frame as the
/// build, and the old element is disposed only when the inactive-element list
/// is finalised at the end of that frame. So the ordering is:
///
///   1. The new layer resolves tile U. It finds the old layer's still-in-
///      flight entry for U in the image cache and adopts that completer, so it
///      makes no new request.
///   2. The old layer is disposed, which completes `TileImage.cancelLoading`
///      and aborts that request.
///   3. flutter_map treats an aborted request as a *successful* load of a
///      transparent tile, because its `on RequestAbortedException` branch
///      decodes `TileProvider.transparentImage`. The completer that both
///      layers share therefore resolves to a blank image.
///
/// The new layer's tile is now permanently 'loaded' and permanently empty. It
/// is not an error, so `errorTileCallback` never fires. That leaves no
/// failed-tile banner and no broken-tile placeholder, and `TileImageManager`
/// will not re-request a tile whose `loadStarted` is set. Every tile that
/// happened to be in flight when the layer re-keyed goes silently blank until
/// the process restarts.
///
/// On the radar that means the whole overlay. A re-key starts the visible
/// frame's entire grid at once, so the next re-key a few seconds later blanks
/// most of it. That next re-key is one more even-zoom crossing while the rider
/// pans around. This is the 'overlays stop loading when I navigate' failure.
/// It shows up in the debug sheet as frames stuck on *pending*, with no radar
/// requests in flight and none in the recent log. The layers genuinely never
/// ask for anything.
///
/// The fix is to refuse to adopt an in-flight entry. Drop that entry from the
/// cache just before the new [TileImage] resolves, so the new [TileImage]
/// starts its own request. This runs inside
/// [getImageWithCancelLoadingSupport], which flutter_map calls from
/// `_createTileImage` immediately before `TileImage.load()`, so nothing in
/// between can undo the eviction.
///
/// Entries that have *finished* are left alone, so panning back over ground
/// already loaded still comes out of memory rather than off the network. That
/// is safe, because a transparent-on-abort result can never become a finished
/// cache entry. flutter_map evicts the URL before it decodes the placeholder,
/// so only genuine tile bytes are ever cached.
///
/// (This is the same class of bug as the flutter_map tile cache singleton that
/// the map view disables. Both are process-wide state that a tile-epoch re-key
/// cannot reset, so a bad entry outlives every in-app retry. Flutter's image
/// cache is the second such singleton in the tile path.)
class RekeySafeTileProvider extends NetworkTileProvider {
  RekeySafeTileProvider({super.httpClient, super.cachingProvider});

  @override
  ImageProvider getImageWithCancelLoadingSupport(
    TileCoordinates coordinates,
    TileLayer options,
    Future<void> cancelLoading,
  ) {
    final provider = super.getImageWithCancelLoadingSupport(
      coordinates,
      options,
      cancelLoading,
    );
    // The returned provider *is* its own cache key (flutter_map's tile image
    // provider returns `this` from obtainKey, with equality on the URL), so it
    // can be handed straight to the cache.
    final cache = PaintingBinding.instance.imageCache;
    if (cache.statusForKey(provider).pending) cache.evict(provider);
    return provider;
  }
}
