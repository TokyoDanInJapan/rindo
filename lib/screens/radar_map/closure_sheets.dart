import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../closures/road_closure.dart';
import 'closure_presentation.dart';

/// Bottom sheets for the closure list and for a single closure's details. Both
/// sheets pad their bottom by the system view padding. This keeps the last row
/// and the source button clear of the navigation overlay, whether that overlay
/// is the gesture bar or the buttons.

void showClosureList(
  BuildContext context, {
  required List<RoadClosure> closures,
  required LatLng? center,
  required bool pinned,
  required bool loading,
  required double radiusKm,
  required String attribution,
  required void Function(RoadClosure) onSelect,
  bool routeMode = false,
}) {
  final scope = routeMode
      ? ' of the route'
      : pinned
      ? ' of the pin'
      : '';
  final now = DateTime.now();
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      if (closures.isEmpty) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            24,
            24,
            24 + MediaQuery.viewPaddingOf(ctx).bottom,
          ),
          child: Text(
            loading
                ? 'Checking for closures…'
                : center == null && !routeMode
                ? 'Waiting for a GPS fix before the search for closures '
                      'starts. Or long-press the map to drop a pin.'
                : 'No reported closures within ${radiusKm.round()} km'
                      '$scope.\n\n'
                      'Source: $attribution',
            textAlign: TextAlign.center,
          ),
        );
      }
      return ListView(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewPaddingOf(ctx).bottom + 8,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              'Closures and alerts within ${radiusKm.round()} km'
              '$scope (${closures.length})',
              style: Theme.of(ctx).textTheme.titleMedium,
            ),
          ),
          for (final c in closures)
            ListTile(
              leading: Icon(closureIcon(c), color: closureColor(c, now)),
              title: Text('${c.roadName} – ${c.restriction}'),
              subtitle: Text(
                [
                  if (center != null)
                    '${c.distanceKmFrom(center).toStringAsFixed(1)} km away',
                  if (c.statusAt(now) == ClosureStatus.scheduled &&
                      c.validFrom != null)
                    'closes ${ymd(c.validFrom!)}',
                  if (c.section != null) c.section!,
                  if (c.cause != null) c.cause!,
                ].join(' · '),
              ),
              onTap: () {
                Navigator.pop(ctx);
                onSelect(c);
              },
            ),
        ],
      );
    },
  );
}

void showClosureDetail(
  BuildContext context,
  RoadClosure c, {
  required LatLng? center,
  required bool pinned,
  required void Function(Uri) onOpenSource,
}) {
  final now = DateTime.now();
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.fromLTRB(
        24,
        0,
        24,
        24 + MediaQuery.viewPaddingOf(ctx).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${c.roadName} – ${c.restriction}',
            style: Theme.of(ctx).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          if (c.section != null) Text('Section: ${c.section}'),
          if (c.cause != null) Text('Cause: ${c.cause}'),
          if (c.period != null) Text('Period: ${c.period}'),
          if (c.isSeasonal && c.validFrom != null && c.validUntil != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                c.statusAt(now) == ClosureStatus.scheduled
                    ? 'Seasonal gate: closes ${ymd(c.validFrom!)}, reopens '
                          'about ${ymd(c.validUntil!)}. These dates are '
                          'nominal. Confirm locally before you ride.'
                    : 'Winter closure in effect: reopens about '
                          '${ymd(c.validUntil!)}. This date is nominal. '
                          'Confirm locally.',
                style: TextStyle(color: Colors.indigo.shade400),
              ),
            ),
          if (center != null)
            Text(
              'Distance: ${c.distanceKmFrom(center).toStringAsFixed(1)} km'
              '${pinned ? ' from pin' : ''}',
            ),
          const SizedBox(height: 16),
          FilledButton.icon(
            icon: const Icon(Icons.open_in_new),
            label: Text('Source: ${c.sourceName}'),
            onPressed: () => onOpenSource(c.sourceUrl),
          ),
        ],
      ),
    ),
  );
}
