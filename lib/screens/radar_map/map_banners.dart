import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../net/net_error.dart';
import '../../translate/closure_translator.dart';
import 'model_download_banner.dart';
import 'screen_margin.dart';

/// A dismissable error banner, so the caller knows which one the user closed.
enum MapBanner { offline, tiles, radar, location, closures }

/// The stack of status/error banners under the frame controls. Each is shown
/// only when its condition holds; the model download gets its own animated
/// banner, the rest are simple error cards.
class MapBanners extends StatelessWidget {
  final bool offline;
  final bool offlineDismissed;
  final bool english;
  final TranslatorStatus translatorStatus;
  final String? translatorError;
  final DateTime? downloadStartedAt;
  final bool translating;
  final String? radarError;
  final String? locationError;
  final String? closuresError;
  final int failedTileCount;
  final VoidCallback? onRetryTiles;

  /// Tapped the × on an error banner. The screen clears that error's source
  /// so it stays gone until the condition recurs.
  final void Function(MapBanner)? onDismiss;

  const MapBanners({
    super.key,
    required this.offline,
    required this.english,
    required this.translatorStatus,
    required this.translatorError,
    required this.downloadStartedAt,
    required this.translating,
    required this.radarError,
    required this.locationError,
    required this.closuresError,
    this.offlineDismissed = false,
    this.failedTileCount = 0,
    this.onRetryTiles,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // One connectivity line covers the whole outage. The per-source radar
        // and closures failures below are the same lost connection, so they're
        // suppressed while this shows - no stack of three red cards.
        if (offline && !offlineDismissed)
          _error(
            context,
            'No connection - map, radar, and closures may be stale. '
            'Retries automatically, or tap ↻.',
            dismiss: MapBanner.offline,
          ),
        // Non-offline tile failures (server errors, timeouts): visible and
        // retryable in one tap.
        if (!offline && failedTileCount > 0)
          _error(
            context,
            '$failedTileCount map tile${failedTileCount == 1 ? '' : 's'} '
            'failed to load - tap to retry.',
            onTap: onRetryTiles,
            dismiss: MapBanner.tiles,
          ),
        if (english && translatorStatus == TranslatorStatus.downloadingModel)
          ModelDownloadBanner(startedAt: downloadStartedAt ?? DateTime.now()),
        if (english && translatorStatus == TranslatorStatus.failed)
          _error(
            context,
            'Translation model unavailable - showing Japanese. '
            '${translatorError ?? ''} Retries on ↻.',
          ),
        if (translating && translatorStatus == TranslatorStatus.ready)
          _error(context, 'Translating closures…'),
        if (!offline && radarError != null)
          _error(
            context,
            _friendly('Radar', radarError!),
            dismiss: MapBanner.radar,
          ),
        if (locationError != null)
          _error(context, locationError!, dismiss: MapBanner.location),
        if (!offline && closuresError != null)
          _error(
            context,
            _friendly('Closures', closuresError!),
            dismiss: MapBanner.closures,
          ),
      ],
    );
  }

  /// Rider-facing copy for a raw fetch exception. The raw text (SocketException,
  /// errno, port, URL) is developer noise, so connectivity failures collapse to
  /// a plain "no connection" line; the raw string is kept only in debug builds.
  static String _friendly(String label, String raw) {
    final msg = looksLikeConnectivityError(raw)
        ? '$label unavailable - no connection.'
        : '$label unavailable right now.';
    return kDebugMode ? '$msg\n$raw' : msg;
  }

  Widget _error(
    BuildContext context,
    String msg, {
    VoidCallback? onTap,
    MapBanner? dismiss,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final canDismiss = dismiss != null && onDismiss != null;
    return Card(
      color: scheme.errorContainer,
      margin: const EdgeInsets.fromLTRB(screenMargin, 4, screenMargin, 0),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  msg,
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
              if (onTap != null)
                Icon(Icons.refresh, size: 18, color: scheme.onErrorContainer),
              if (canDismiss)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: IconButton(
                    tooltip: 'Dismiss',
                    icon: const Icon(Icons.close),
                    iconSize: 18,
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                    color: scheme.onErrorContainer,
                    onPressed: () => onDismiss!(dismiss),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
