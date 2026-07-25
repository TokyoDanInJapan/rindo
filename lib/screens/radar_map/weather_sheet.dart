import 'dart:async';

import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';

import '../../jma/jma_forecast.dart';
import 'weather_presentation.dart';

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
      // Two tables plus the wording need the room; the rider can still drag it
      // up to 0.9 or down out of the way.
      initialChildSize: 0.7,
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
        _Section(
          title: 'Forecast',
          child: _NearTerm(
            days: report.days,
            rainByDay: rainByDay,
            label: (d) => _dayLabel(d, today),
          ),
        ),
        _Section(
          title: 'Day by day',
          child: _Wording(
            days: report.days,
            label: (d) => _dayLabel(d, today),
          ),
        ),
        if (report.week.isNotEmpty)
          _Section(
            title: 'Week ahead',
            child: _WeekTable(week: report.week),
          ),
        if (report.overview.isNotEmpty)
          _Section(
            title: 'Outlook',
            child: Text(report.overview, style: text.bodyMedium),
          ),
        _Section(
          title: 'Source',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${report.office} · issued ${jstHhmm(report.reportedAt)} JST',
                style: text.bodySmall,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                icon: const Icon(Icons.open_in_new),
                label: const Text('気象庁 天気予報'),
                onPressed: () => onOpenSource(report.sourceUrl),
              ),
            ],
          ),
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

/// One titled block, ruled off from the one above it.
///
/// The sheet stacks five kinds of thing that look alike at a glance - two
/// tables of numbers, two runs of Japanese prose, and the attribution - so
/// without a rule between them a thumb-scroll reads as one long column and it
/// stops being obvious which numbers belong to which day range. The line does
/// the separating; the title says what you're looking at.
class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const SizedBox(height: 16),
      const Divider(height: 1),
      const SizedBox(height: 12),
      Text(
        title,
        // Quiet and lettered-out: a signpost, not a competitor for the
        // forecast underneath it.
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          letterSpacing: 1.1,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
      const SizedBox(height: 8),
      child,
    ],
  );
}

/// Anything from "likely" upward is the number a rider changes plans over.
const _notableRain = 50;

/// The 6-hour blocks JMA reports rain chance in, as its own page columns them.
/// Fixed rather than derived from the response: a block that has already passed
/// is simply dropped from the data, and a table whose columns move about
/// between morning and afternoon is harder to read than one with a gap in it.
const _rainBlocks = [0, 6, 12, 18];

/// The chance published for the block starting at [hour], or null if JMA no
/// longer reports it (the block has passed).
int? _popAt(List<RainChance>? day, int hour) {
  for (final r in day ?? const <RainChance>[]) {
    if (jstHour(r.at) == hour) return r.percent;
  }
  return null;
}

TextStyle? _rainStyle(TextTheme text, int? percent) => text.bodyMedium?.copyWith(
  fontWeight: (percent ?? 0) >= _notableRain
      ? FontWeight.bold
      : FontWeight.normal,
  color: (percent ?? 0) >= _notableRain ? Colors.blue.shade700 : null,
);

Widget _cell(Widget child, {Alignment align = Alignment.center}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
  child: Align(alignment: align, child: child),
);

/// Today and tomorrow, laid out the way JMA's own page does: a column per day
/// carrying the icon and temperatures, then rain chance as a grid of fixed
/// 6-hour blocks.
///
/// JMA's wording is the one thing that does *not* go in a cell - 「くもり時々晴
/// れ夜のはじめ頃一時雨所により夕方から雷を伴い激しく降る」in a column two
/// fingers wide is a vertical smear. It sits under the table instead, where it
/// stays a sentence, which is what makes it worth more than the icon above it.
class _NearTerm extends StatelessWidget {
  const _NearTerm({
    required this.days,
    required this.rainByDay,
    required this.label,
  });

  final List<WeatherDay> days;
  final Map<(int, int), List<RainChance>> rainByDay;
  final String Function((int, int)) label;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _scrollable(
          Table(
            defaultColumnWidth: const FixedColumnWidth(96),
            columnWidths: const {0: IntrinsicColumnWidth()},
            children: [
              TableRow(
                children: [
                  _cell(const SizedBox.shrink()),
                  for (final d in days)
                    _cell(
                      Text(label(jstDate(d.at)), style: text.titleSmall),
                    ),
                ],
              ),
              TableRow(
                children: [
                  _cell(Text('Weather', style: text.bodySmall)),
                  for (final d in days)
                    _cell(
                      Icon(
                        weatherIcon(d.code),
                        color: weatherColor(d.code, context),
                        size: 30,
                      ),
                    ),
                ],
              ),
              TableRow(
                children: [
                  _cell(Text('Temp', style: text.bodySmall)),
                  for (final d in days)
                    _cell(
                      Text(
                        [
                          if (d.tempMax case final max?) '↑$max°',
                          if (d.tempMin case final min?) '↓$min°',
                        ].join(' '),
                        style: text.bodyMedium,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _scrollable(_rainGrid(context)),
      ],
    );
  }

  Widget _rainGrid(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Table(
      defaultColumnWidth: const FixedColumnWidth(66),
      columnWidths: const {0: IntrinsicColumnWidth()},
      children: [
        TableRow(
          children: [
            _cell(Text('Rain %', style: text.bodySmall)),
            for (final h in _rainBlocks)
              _cell(
                Text(
                  '${h.toString().padLeft(2, '0')}-'
                  '${((h + 6) % 24).toString().padLeft(2, '0')}',
                  style: text.bodySmall,
                ),
              ),
          ],
        ),
        for (final d in days)
          TableRow(
            children: [
              _cell(
                Text(label(jstDate(d.at)), style: text.bodySmall),
                align: Alignment.centerLeft,
              ),
              for (final h in _rainBlocks)
                _cell(() {
                  final pop = _popAt(rainByDay[jstDate(d.at)], h);
                  return Text(
                    pop == null ? '–' : '$pop',
                    style: _rainStyle(text, pop),
                  );
                }()),
            ],
          ),
      ],
    );
  }
}

/// JMA's wording for each day, kept out of the table above it: 「くもり時々晴れ
/// 夜のはじめ頃一時雨所により夕方から雷を伴い激しく降る」in a column two fingers
/// wide is a vertical smear. As a sentence it stays the most informative thing
/// on the sheet - it's the part an icon can't carry.
class _Wording extends StatelessWidget {
  const _Wording({required this.days, required this.label});

  final List<WeatherDay> days;
  final String Function((int, int)) label;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final d in days) ...[
          Text(label(jstDate(d.at)), style: text.titleSmall),
          Text(d.weather, style: text.bodyMedium),
          if ([
            if (d.wind case final w? when w.isNotEmpty) 'Wind: $w',
            if (d.wave case final w? when w.isNotEmpty) 'Waves: $w',
          ].join(' · ') case final detail when detail.isNotEmpty)
            Text(detail, style: text.bodySmall),
          if (d != days.last) const SizedBox(height: 10),
        ],
      ],
    );
  }
}

/// The 週間予報: a column per day, all numbers and icons because that is all
/// JMA publishes this far out.
class _WeekTable extends StatelessWidget {
  const _WeekTable({required this.week});

  final List<WeeklyDay> week;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    String temp(int? v) => v == null ? '–' : '$v°';

    return _scrollable(
      Table(
        defaultColumnWidth: const FixedColumnWidth(52),
        columnWidths: const {0: IntrinsicColumnWidth()},
        children: [
          TableRow(
            children: [
              _cell(const SizedBox.shrink()),
              for (final d in week)
                _cell(
                  Text(
                    '${jstDate(d.at).$1}/${jstDate(d.at).$2}',
                    style: text.bodySmall,
                  ),
                ),
            ],
          ),
          TableRow(
            children: [
              _cell(Text('Weather', style: text.bodySmall)),
              for (final d in week)
                _cell(
                  Icon(
                    weatherIcon(d.code),
                    color: weatherColor(d.code, context),
                    size: 24,
                  ),
                ),
            ],
          ),
          TableRow(
            children: [
              _cell(Text('Rain %', style: text.bodySmall)),
              for (final d in week)
                _cell(
                  Text(
                    d.pop == null ? '–' : '${d.pop}',
                    style: _rainStyle(text, d.pop),
                  ),
                ),
            ],
          ),
          TableRow(
            children: [
              _cell(Text('Max', style: text.bodySmall)),
              for (final d in week)
                _cell(Text(temp(d.tempMax), style: text.bodyMedium)),
            ],
          ),
          TableRow(
            children: [
              _cell(Text('Min', style: text.bodySmall)),
              for (final d in week)
                _cell(Text(temp(d.tempMin), style: text.bodyMedium)),
            ],
          ),
          TableRow(
            children: [
              // JMA's own confidence grade. A forecast five days out with a C
              // beside it is worth planning around differently to one with an A.
              _cell(Text('Conf.', style: text.bodySmall)),
              for (final d in week)
                _cell(Text(d.reliability ?? '–', style: text.bodySmall)),
            ],
          ),
        ],
      ),
    );
  }
}

/// Tables are wider than a phone once there are more than a couple of columns,
/// so each scrolls inside its own box rather than forcing the whole sheet
/// sideways.
Widget _scrollable(Widget table) =>
    SingleChildScrollView(scrollDirection: Axis.horizontal, child: table);
