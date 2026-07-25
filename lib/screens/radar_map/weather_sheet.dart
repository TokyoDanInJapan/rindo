import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../jma/jma_forecast.dart';

/// What tapping a place on the map offers. Weather is the reason it exists;
/// clearing the pin used to be the pin's own tap action, so it moves in here
/// rather than being lost.
///
/// The rider marker gets the same sheet with one entry - a menu of one is
/// thinner than it could be, but it keeps a single tap gesture meaning a single
/// thing wherever it lands, and leaves somewhere obvious to hang the next
/// per-place action.
void showPlaceSheet(
  BuildContext context, {
  required bool pinned,
  required VoidCallback onWeather,
  required VoidCallback onClearPin,
}) {
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.cloud_outlined),
            title: const Text('Weather here'),
            subtitle: Text(
              pinned ? 'JMA forecast for the pin' : 'JMA forecast for your spot',
            ),
            onTap: () {
              Navigator.pop(ctx);
              onWeather();
            },
          ),
          if (pinned)
            ListTile(
              leading: const Icon(Icons.location_off_outlined),
              title: const Text('Clear pin'),
              subtitle: const Text('Search around the rider again'),
              onTap: () {
                Navigator.pop(ctx);
                onClearPin();
              },
            ),
        ],
      ),
    ),
  );
}

/// Bottom sheet for the JMA area forecast at a point on the map.
///
/// Fetches when it opens rather than being handed a report: the rider asks for
/// the weather *somewhere*, and holding a prefetched forecast for a position
/// they might never tap would mean refetching it on every pan. Same bottom
/// padding as the closure sheets, so the source button clears the navigation
/// overlay.
/// [translate] is supplied only in English mode. The report shows in Japanese
/// the moment it arrives and the English swaps in behind it, rather than the
/// spinner sitting there through a first-run model download - the same order
/// the closure list uses, and the reason the fetch and the translation are two
/// steps here instead of one composed future.
void showWeatherSheet(
  BuildContext context, {
  required LatLng at,
  required Future<WeatherReport> Function(LatLng) load,
  required void Function(Uri) onOpenSource,
  Future<WeatherReport> Function(WeatherReport)? translate,
}) {
  // Started before the sheet builds, so a rebuild (drag, keyboard, rotation)
  // can't kick off a second fetch.
  final pending = load(at);
  // FutureBuilder only subscribes once the route has built, a frame later. A
  // fetch that fails inside that window - an instant "no forecast area here",
  // or a socket that's already dead - would otherwise have no listener at the
  // moment it completes and get reported as an unhandled async error, which in
  // debug builds is a red screen over the map. Claiming the error here marks it
  // handled; FutureBuilder still receives it and renders the message.
  unawaited(pending.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  showModalBottomSheet(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.6,
      maxChildSize: 0.9,
      builder: (ctx, scroll) => FutureBuilder<WeatherReport>(
        future: pending,
        builder: (ctx, snap) => Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            0,
            24,
            24 + MediaQuery.viewPaddingOf(ctx).bottom,
          ),
          child: switch (snap) {
            AsyncSnapshot(connectionState: ConnectionState.waiting) =>
              const _Centred(child: CircularProgressIndicator()),
            AsyncSnapshot(hasError: true, :final error) => _Centred(
              child: Text(
                _friendlyError(error!),
                textAlign: TextAlign.center,
              ),
            ),
            AsyncSnapshot(data: final report?) => _MaybeTranslated(
              report: report,
              translate: translate,
              scroll: scroll,
              onOpenSource: onOpenSource,
            ),
            _ => const _Centred(child: SizedBox.shrink()),
          },
        ),
      ),
    ),
  );
}

/// The rider is on a bike in the rain; "JmaForecastException: forecast 503"
/// helps nobody. Connectivity and coverage are the two they can act on.
String _friendlyError(Object error) {
  final raw = '$error';
  if (raw.contains('no JMA forecast area')) {
    return "JMA doesn't publish a forecast for this position - it only covers "
        'Japan. Move the map (or drop a pin) somewhere inland.';
  }
  return "Couldn't reach the JMA forecast just now. Check your connection and "
      'try again.';
}

class _Centred extends StatelessWidget {
  const _Centred({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      SizedBox(height: 160, child: Center(child: child));
}

/// Shows the report as fetched, then replaces it with the English copy once
/// that lands. Stateful because the translation is a second, slower step: the
/// first one ever can be a ~30 MB model download, and a rider who opened the
/// sheet to decide whether to set off should be reading JMA's Japanese in the
/// meantime rather than a spinner.
class _MaybeTranslated extends StatefulWidget {
  const _MaybeTranslated({
    required this.report,
    required this.translate,
    required this.scroll,
    required this.onOpenSource,
  });

  final WeatherReport report;
  final Future<WeatherReport> Function(WeatherReport)? translate;
  final ScrollController scroll;
  final void Function(Uri) onOpenSource;

  @override
  State<_MaybeTranslated> createState() => _MaybeTranslatedState();
}

class _MaybeTranslatedState extends State<_MaybeTranslated> {
  late WeatherReport _shown = widget.report;
  // Seeded rather than set from initState: the async body below runs
  // synchronously up to its first await, so flipping this with setState would
  // be a setState during the build that is mounting this very widget. Harmless
  // today (the element is already dirty, so markNeedsBuild is a no-op) but only
  // by accident, and it reads like a bug either way.
  late bool _translating = widget.translate != null;

  @override
  void initState() {
    super.initState();
    _translate();
  }

  Future<void> _translate() async {
    final translate = widget.translate;
    if (translate == null) return;
    try {
      final english = await translate(widget.report);
      if (mounted) setState(() => _shown = english);
    } catch (_) {
      // Same contract as the closure list: a translation that fails leaves
      // the Japanese on screen. It's the source of record either way.
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Report(
    report: _shown,
    translating: _translating,
    scroll: widget.scroll,
    onOpenSource: widget.onOpenSource,
  );
}

class _Report extends StatelessWidget {
  const _Report({
    required this.report,
    required this.translating,
    required this.scroll,
    required this.onOpenSource,
  });

  final WeatherReport report;
  final bool translating;
  final ScrollController scroll;
  final void Function(Uri) onOpenSource;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final today = jstDate(DateTime.now().toUtc());
    // JMA publishes rain chances on their own clock, so bucket them by day and
    // show each day's under that day's forecast rather than as a separate run
    // of times the rider has to line up by eye.
    final rainByDay = <(int, int), List<RainChance>>{};
    for (final r in report.rain) {
      (rainByDay[jstDate(r.at)] ??= []).add(r);
    }

    return ListView(
      controller: scroll,
      children: [
        Row(
          children: [
            Expanded(child: Text(report.areaName, style: text.titleLarge)),
            // Deliberately understated: the Japanese below it is readable and
            // correct, so this is progress, not a blocked state.
            if (translating) ...[
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Text('Translating…', style: text.bodySmall),
            ],
          ],
        ),
        Text(
          '${report.area.municipality} · '
          '${report.area.km.toStringAsFixed(0)} km away',
          style: text.bodySmall,
        ),
        if (report.headline case final headline?) ...[
          const SizedBox(height: 12),
          Card(
            color: Colors.amber.shade100,
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.warning_amber, size: 20),
                  const SizedBox(width: 8),
                  Expanded(child: Text(headline)),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 8),
        for (final day in report.days)
          _Day(
            day: day,
            label: _dayLabel(jstDate(day.at), today),
            rain: rainByDay[jstDate(day.at)] ?? const [],
          ),
        if (report.overview.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Outlook', style: text.titleSmall),
          const SizedBox(height: 4),
          Text(report.overview, style: text.bodyMedium),
        ],
        const SizedBox(height: 16),
        Text(
          '${report.office} · issued ${jstHhmm(report.reportedAt)} JST',
          style: text.bodySmall,
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          icon: const Icon(Icons.open_in_new),
          label: const Text('Source: 気象庁 天気予報'),
          onPressed: () => onOpenSource(report.sourceUrl),
        ),
      ],
    );
  }

  /// "Today"/"Tomorrow" where that's true, otherwise a bare date - the forecast
  /// only ever reaches a couple of days out, so a weekday name would be more
  /// words for no more information.
  static String _dayLabel((int, int) day, (int, int) today) {
    if (day == today) return 'Today';
    final tomorrow = jstDate(
      DateTime.now().toUtc().add(const Duration(days: 1)),
    );
    if (day == tomorrow) return 'Tomorrow';
    return '${day.$1}/${day.$2}';
  }
}

class _Day extends StatelessWidget {
  const _Day({required this.day, required this.label, required this.rain});

  final WeatherDay day;
  final String label;
  final List<RainChance> rain;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final detail = [
      if (day.wind case final wind? when wind.isNotEmpty) 'Wind: $wind',
      if (day.wave case final wave? when wave.isNotEmpty) 'Waves: $wave',
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(label, style: text.titleSmall),
              const Spacer(),
              if (day.tempMax != null || day.tempMin != null)
                Text(
                  [
                    if (day.tempMax case final max?) '↑$max°',
                    if (day.tempMin case final min?) '↓$min°',
                  ].join('  '),
                  style: text.titleSmall,
                ),
            ],
          ),
          Text(day.weather, style: text.bodyMedium),
          if (rain.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 12,
                children: [
                  for (final r in rain)
                    Text(
                      '${jstHhmm(r.at)} ${r.percent}%',
                      style: text.bodySmall?.copyWith(
                        // Anything from "likely" upward is the number a rider
                        // changes plans over, so let it carry weight.
                        fontWeight: r.percent >= 50
                            ? FontWeight.bold
                            : FontWeight.normal,
                        color: r.percent >= 50 ? Colors.blue.shade700 : null,
                      ),
                    ),
                ],
              ),
            ),
          if (detail.isNotEmpty)
            Text(detail.join(' · '), style: text.bodySmall),
        ],
      ),
    );
  }
}
