import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../jma/jma_api.dart';
import '../../net/asset_monitor.dart';

/// Snapshot of everything the screen knows about loading, taken fresh each
/// time the sheet repaints. Defaults exist only so tests can build partials;
/// the screen passes every field.
class DebugScreenState {
  final double? cameraZoom;
  final String? cameraCenter;
  final bool offline;
  final bool pastStartupGrace;
  final bool offlineDismissed;
  final int tileEpoch;
  final int reconnectAttempt;
  final int failedTileCount;
  final String? lastTileError;
  final List<JmaFrame> frames;
  final int frameIndex;

  /// The even level the radar layers are pinned to (see jmaNativeZoom);
  /// per-frame load states in the report are for this zoom.
  final int? radarNativeZoom;
  final String? radarError;
  final bool hasFix;
  final String? locationError;
  final int closureCount;
  final bool closuresLoading;
  final String? closuresError;
  final String translatorStatus;
  final bool translating;

  const DebugScreenState({
    this.cameraZoom,
    this.cameraCenter,
    this.offline = false,
    this.pastStartupGrace = true,
    this.offlineDismissed = false,
    this.tileEpoch = 0,
    this.reconnectAttempt = 0,
    this.failedTileCount = 0,
    this.lastTileError,
    this.frames = const [],
    this.frameIndex = 0,
    this.radarNativeZoom,
    this.radarError,
    this.hasFix = false,
    this.locationError,
    this.closureCount = 0,
    this.closuresLoading = false,
    this.closuresError,
    this.translatorStatus = 'idle',
    this.translating = false,
  });
}

String _clock(DateTime d) {
  final l = d.toLocal();
  String p(int n) => n.toString().padLeft(2, '0');
  return '${p(l.hour)}:${p(l.minute)}:${p(l.second)}';
}

String _fmtBytes(int b) {
  if (b >= 1024 * 1024) return '${(b / (1024 * 1024)).toStringAsFixed(1)} MB';
  if (b >= 1024) return '${(b / 1024).toStringAsFixed(1)} kB';
  return '$b B';
}

String _oneLine(String s, [int max = 100]) {
  final flat = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= max ? flat : '${flat.substring(0, max)}…';
}

String _ageStr(Duration d) {
  if (d.inSeconds < 60) {
    return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
  }
  return '${d.inMinutes}m${(d.inSeconds % 60).toString().padLeft(2, '0')}s';
}

String _tallyLine(AssetTally t, int active) {
  final parts = <String>[
    'ok ${t.ok}'
        '${t.ok > 0 ? ' (${_fmtBytes(t.okBytes)}, avg ${_fmtBytes(t.okBytes ~/ t.ok)})' : ''}',
    if (t.notFound > 0) '404 ${t.notFound}',
    if (t.httpError > 0) 'http-err ${t.httpError}',
    if (t.failed > 0) 'failed ${t.failed}',
    if (t.cancelled > 0) 'cancelled ${t.cancelled}',
    if (active > 0) 'in-flight $active',
  ];
  return parts.join(' · ');
}

/// The whole debug story as plain text: shown in the sheet and copied to the
/// clipboard verbatim, so what gets pasted into a bug report is exactly what
/// was on screen. The per-zoom average body size is the tell for "no rain at
/// this zoom": JMA serves blank tiles as tiny 200s, not 404s.
String buildAssetDebugReport({
  required AssetMonitor monitor,
  required DebugScreenState s,
  DateTime? now,
}) {
  final t = now ?? DateTime.now();
  String flag(bool b) => b ? 'yes' : 'no';
  String err(String? e) => e == null ? '-' : _oneLine(e);

  final b = StringBuffer();
  b.writeln('ASSET DEBUG  ${_clock(t)}');
  if (s.cameraZoom != null) {
    b.writeln(
      'camera  z${s.cameraZoom!.toStringAsFixed(2)} @ ${s.cameraCenter}',
    );
  }
  b.writeln();

  b.writeln('SCREEN');
  b.writeln(
    '  connectivity  ${s.offline ? 'OFFLINE' : 'online'}'
    '${s.pastStartupGrace ? '' : ' (startup grace)'}'
    '${s.offlineDismissed ? ' · banner dismissed' : ''}',
  );
  b.writeln(
    '  tile epoch    ${s.tileEpoch}'
    ' · failed-tile banner ${s.failedTileCount}',
  );
  if (s.lastTileError != null) {
    b.writeln('  last tile err ${err(s.lastTileError)}');
  }
  b.writeln('  reconnect     attempt ${s.reconnectAttempt}');
  b.writeln(
    '  location      ${s.hasFix ? 'fix ok' : 'no fix'}'
    ' · error ${err(s.locationError)}',
  );
  b.writeln(
    '  closures      ${s.closureCount} shown'
    ' · loading ${flag(s.closuresLoading)} · error ${err(s.closuresError)}',
  );
  b.writeln(
    '  translator    ${s.translatorStatus}'
    ' · translating ${flag(s.translating)}',
  );
  b.writeln();

  final radarZ = s.radarNativeZoom;
  b.writeln(
    'RADAR FRAMES  ${s.frames.length} · error ${err(s.radarError)}'
    '${radarZ != null ? ' · fetching z$radarZ' : ''}',
  );
  for (var i = 0; i < s.frames.length; i++) {
    final f = s.frames[i];
    final state = radarZ == null
        ? ''
        : ' · ${monitor.frameState(f.validtime, radarZ).name}';
    b.writeln(
      '  ${i == s.frameIndex ? '▶' : ' '} ${f.offsetLabel.padLeft(4)}'
      '  ${f.jstLabel} JST · valid ${f.validtime}$state',
    );
  }
  b.writeln();

  final inFlight = monitor.inFlight;
  b.writeln('NETWORK  counting since ${_clock(monitor.countingSince)}');
  for (final kind in AssetKind.values) {
    final st = monitor.stats[kind]!;
    final active = inFlight.where((r) => r.kind == kind).length;
    if (st.all.total == 0 && active == 0) continue;
    b.writeln(assetKindLabel(kind));
    b.writeln('  ${_tallyLine(st.all, active)}');
    for (final e in st.byZoom.entries) {
      final zActive = inFlight
          .where((r) => r.kind == kind && r.z == e.key)
          .length;
      b.writeln(
        '  z${e.key.toString().padRight(2)} '
        '${_tallyLine(e.value, zActive)}',
      );
    }
    if (st.lastError != null) {
      b.writeln(
        '  last error ${_oneLine(st.lastError!)}'
        '${st.lastErrorAt != null ? ' (${_clock(st.lastErrorAt!)})' : ''}',
      );
    }
  }
  b.writeln();

  b.writeln('IN FLIGHT (${inFlight.length})');
  for (final r in inFlight) {
    final age = t.difference(r.startedAt);
    b.writeln(
      '  ${_ageStr(age).padLeft(6)}  ${r.shortName}  '
      '${r.statusCode == null ? 'awaiting response' : 'receiving body (${_fmtBytes(r.bytes)})'}',
    );
  }
  b.writeln();

  final all = monitor.recent;
  final recent = all.reversed.take(30).toList();
  b.writeln('RECENT (newest first, ${recent.length} of ${all.length})');
  for (final r in recent) {
    final String outcome;
    if (r.cancelled) {
      outcome = 'cancelled';
    } else if (r.error != null) {
      outcome = 'FAIL ${_oneLine(r.error!, 60)}';
    } else if (r.ok) {
      outcome =
          '${r.statusCode} ${_fmtBytes(r.bytes)} '
          '${r.endedAt!.difference(r.startedAt).inMilliseconds}ms';
    } else {
      outcome = 'HTTP ${r.statusCode}';
    }
    b.writeln('  ${_clock(r.startedAt)}  ${r.shortName}  $outcome');
  }
  return b.toString();
}

Future<void> showAssetDebugSheet(
  BuildContext context, {
  required AssetMonitor monitor,
  required DebugScreenState Function() snapshot,
}) => showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.7,
    minChildSize: 0.3,
    maxChildSize: 0.95,
    builder: (context, controller) => AssetDebugSheet(
      monitor: monitor,
      snapshot: snapshot,
      scrollController: controller,
    ),
  ),
);

/// Live view of [buildAssetDebugReport]: repaints on monitor activity and on
/// a 1 s tick (for in-flight ages), with copy-to-clipboard and counter reset.
class AssetDebugSheet extends StatefulWidget {
  final AssetMonitor monitor;
  final DebugScreenState Function() snapshot;
  final ScrollController? scrollController;

  const AssetDebugSheet({
    super.key,
    required this.monitor,
    required this.snapshot,
    this.scrollController,
  });

  @override
  State<AssetDebugSheet> createState() => _AssetDebugSheetState();
}

class _AssetDebugSheetState extends State<AssetDebugSheet> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    widget.monitor.addListener(_onChange);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onChange());
  }

  @override
  void dispose() {
    widget.monitor.removeListener(_onChange);
    _tick?.cancel();
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final report = buildAssetDebugReport(
      monitor: widget.monitor,
      s: widget.snapshot(),
    );
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              const Icon(Icons.bug_report_outlined, size: 20),
              const SizedBox(width: 8),
              Text(
                'Asset loading',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Copy report',
                icon: const Icon(Icons.copy, size: 20),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: report));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Report copied')),
                  );
                },
              ),
              IconButton(
                tooltip: 'Reset counters',
                icon: const Icon(Icons.restart_alt, size: 20),
                onPressed: widget.monitor.resetCounters,
              ),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            controller: widget.scrollController,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: SelectableText(
              report,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                height: 1.35,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
