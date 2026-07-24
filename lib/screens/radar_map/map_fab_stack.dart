import 'package:flutter/material.dart';

/// The bottom-right control stack. Dumb: it renders current state and calls
/// back - all the logic lives in the screen.
class MapFabStack extends StatelessWidget {
  final bool routeLoaded;
  final bool english;
  final bool greyscale;
  final int closureCount;
  final bool closuresLoading;
  final bool pinned;
  final bool following;

  final VoidCallback onShowDebug;
  final VoidCallback onToggleRoute;
  final VoidCallback onToggleLanguage;
  final VoidCallback onToggleGreyscale;
  final VoidCallback onShowClosures;
  final VoidCallback onRefresh;
  final VoidCallback onRecenter;

  const MapFabStack({
    super.key,
    required this.routeLoaded,
    required this.english,
    required this.greyscale,
    required this.closureCount,
    required this.closuresLoading,
    required this.pinned,
    required this.following,
    required this.onShowDebug,
    required this.onToggleRoute,
    required this.onToggleLanguage,
    required this.onToggleGreyscale,
    required this.onShowClosures,
    required this.onRefresh,
    required this.onRecenter,
  });

  @override
  Widget build(BuildContext context) {
    // Lifted clear of the corner so the (mandatory) attribution control
    // stays visible beneath the stack.
    return Padding(
      padding: const EdgeInsets.only(bottom: 48),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'debug',
            tooltip: 'Asset loading debug',
            onPressed: onShowDebug,
            child: const Icon(Icons.bug_report_outlined),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: 'route',
            tooltip: routeLoaded
                ? 'Clear the GPX route'
                : 'Load a GPX route to scout',
            backgroundColor: routeLoaded ? Colors.deepPurple.shade100 : null,
            onPressed: onToggleRoute,
            child: Icon(routeLoaded ? Icons.route : Icons.route_outlined),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: 'language',
            tooltip: english
                ? 'Show original Japanese'
                : 'Translate to English',
            onPressed: onToggleLanguage,
            child: Text(
              english ? 'EN' : 'あ',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: 'greyscale',
            tooltip: greyscale ? 'Full-colour map' : 'Greyscale map',
            onPressed: onToggleGreyscale,
            child: Icon(
              greyscale ? Icons.palette_outlined : Icons.filter_b_and_w,
            ),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: 'closures',
            tooltip: 'Nearby road closures',
            onPressed: onShowClosures,
            child: Badge(
              isLabelVisible: closureCount > 0,
              label: Text('$closureCount'),
              child: const Icon(Icons.report_gmailerrorred),
            ),
          ),
          const SizedBox(height: 8),
          FloatingActionButton.small(
            heroTag: 'refresh',
            tooltip: 'Refresh radar + closures',
            onPressed: onRefresh,
            child: closuresLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
          ),
          const SizedBox(height: 8),
          FloatingActionButton(
            heroTag: 'follow',
            tooltip: pinned
                ? 'Drop pin, return to rider'
                : following
                ? 'Following rider'
                : 'Re-centre on rider',
            onPressed: onRecenter,
            child: Icon(
              following ? Icons.my_location : Icons.location_searching,
            ),
          ),
        ],
      ),
    );
  }
}
