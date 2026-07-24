import 'dart:convert';

import 'package:http/http.dart' as http;

/// Direct client for JMA's undocumented nowcast endpoints - the same ones that
/// power https://www.jma.go.jp/bosai/nowc/ (ported from garmin-jma-radar's
/// proxy/src/jma.js). They are not an official API and may change without
/// notice; when JMA breaks something, this is the only file to touch.
///
///   targetTimes: https://www.jma.go.jp/bosai/jmatile/data/nowc/targetTimes_N1.json
///     -> array of { basetime, validtime, elements: [...] }
///   radar tile:  https://www.jma.go.jp/bosai/jmatile/data/nowc/
///                  {basetime}/none/{validtime}/surf/hrpns/{z}/{x}/{y}.png
///
/// "hrpns" = 高解像度降水ナウキャスト (high-resolution precipitation nowcast).
/// Tiles are transparent PNGs (no-rain areas are transparent) meant to overlay
/// a base map. A 404 is normal for an empty (rain-free) tile.
const jmaBase = 'https://www.jma.go.jp/bosai/jmatile/data/nowc';

// N1 = observed/analysis frames (basetime == validtime).
// N2 = forecast frames (validtime > basetime), out to +60 min in 5-min steps.
const _observedUrl = '$jmaBase/targetTimes_N1.json';
const _forecastUrl = '$jmaBase/targetTimes_N2.json';

/// JMA generates hrpns tiles ONLY at even zoom levels, topping out at z10:
/// z4/6/8/10 carry rain pixels, while z5/7/9 and everything above z10 return
/// an empty (transparent) 200 - a subtle 200, not a 404. So no zoom range
/// works as a plain [min,max]: any odd level inside it is blank. The radar
/// layers instead pin their fetch to [jmaNativeZoom] and let the tiles
/// scale to the camera.
const jmaMinZoom = 4;
const jmaMaxZoom = 10;

/// The level the radar layers should actually fetch for a camera zoom: the
/// nearest even level, clamped to z4..z10. Odd camera zooms render a real
/// level scaled by at most 2× either way - slightly blocky or slightly
/// oversampled, but never the invisible-rain blank that fetching z5/7/9
/// produced (the "no rain at some zoom levels" bug).
int jmaNativeZoom(double cameraZoom) {
  final even = (cameraZoom / 2).round() * 2;
  return even.clamp(jmaMinZoom, jmaMaxZoom).toInt();
}

/// Presentation window: 15 min of observed past through 60 min of forecast,
/// sampled every 15 min. All offsets land on JMA's native 5-min grid, so each
/// maps to a real frame. The +35..+60 min forecast is 1 km resolution vs
/// 250 m for the rest - JMA's own limitation.
const frameOffsetsMin = [-15, 0, 15, 30, 45, 60];

/// One radar frame: a (basetime, validtime) pair resolved to a tile URL
/// template plus display labels. Offsets <= 0 are observed, > 0 forecast.
class JmaFrame {
  final String basetime; // "YYYYMMDDHHmmss" UTC - analysis time
  final String validtime; // "YYYYMMDDHHmmss" UTC - time the frame is valid at
  final int offsetMin; // minutes relative to the newest analysis ("now")

  const JmaFrame({
    required this.basetime,
    required this.validtime,
    required this.offsetMin,
  });

  /// Slippy-map URL template for this frame, for use as a raster tile layer.
  String get urlTemplate =>
      '$jmaBase/$basetime/none/$validtime/surf/hrpns/{z}/{x}/{y}.png';

  /// "HH:MM" clock label in JST (UTC+9). Hour wraps at midnight; this is a
  /// clock label, not a date, so the day rollover doesn't matter.
  String get jstLabel {
    final hh = int.parse(validtime.substring(8, 10));
    final mm = validtime.substring(10, 12);
    final jst = (hh + 9) % 24;
    return '${jst.toString().padLeft(2, '0')}:$mm';
  }

  String get offsetLabel =>
      offsetMin == 0 ? 'now' : '${offsetMin > 0 ? '+' : ''}${offsetMin}m';

  bool get isForecast => offsetMin > 0;
}

/// "YYYYMMDDHHmmss" (UTC) -> DateTime (UTC).
DateTime parseJmaTime(String s) => DateTime.utc(
  int.parse(s.substring(0, 4)),
  int.parse(s.substring(4, 6)),
  int.parse(s.substring(6, 8)),
  int.parse(s.substring(8, 10)),
  int.parse(s.substring(10, 12)),
  int.parse(s.substring(12, 14)),
);

/// DateTime (UTC) -> "YYYYMMDDHHmmss".
String formatJmaTime(DateTime d) {
  String p(int n) => n.toString().padLeft(2, '0');
  return '${d.year}${p(d.month)}${p(d.day)}${p(d.hour)}${p(d.minute)}${p(d.second)}';
}

class _TimePair {
  final String basetime;
  final String validtime;
  const _TimePair(this.basetime, this.validtime);
}

/// Client for the targetTimes indexes; assembles the frame set the radar
/// animation plays (see the file header for endpoint details).
class JmaApi {
  final http.Client _client;
  JmaApi({http.Client? client}) : _client = client ?? http.Client();

  /// Fetch one targetTimes index and normalize to time pairs. `observedOnly`
  /// keeps analysis frames (basetime == validtime); otherwise keeps forecast
  /// frames (validtime > basetime). Some JMA responses arrive newest-first and
  /// some oldest-first, so sort defensively rather than trust the order.
  Future<List<_TimePair>> _fetchTimes(
    String url, {
    required bool observedOnly,
  }) async {
    final r = await _client
        .get(Uri.parse(url))
        .timeout(const Duration(seconds: 10));
    if (r.statusCode != 200) {
      throw JmaException('targetTimes ${r.statusCode}');
    }
    final raw = jsonDecode(utf8.decode(r.bodyBytes));
    if (raw is! List) throw JmaException('targetTimes: unexpected shape');

    final pairs = <_TimePair>[];
    for (final t in raw) {
      if (t is! Map) continue;
      final b = t['basetime'], v = t['validtime'];
      if (b is! String || v is! String) continue;
      final keep = observedOnly ? b == v : v.compareTo(b) > 0;
      if (keep) pairs.add(_TimePair(b, v));
    }
    pairs.sort((a, b) => a.validtime.compareTo(b.validtime)); // oldest-first
    return pairs;
  }

  /// Assemble the −15…+60 min frame set (15-min steps), oldest-first.
  /// Past/now frames come from observed (N1), forecast frames from N2; the two
  /// share an anchor because N2's basetime is the latest analysis time.
  /// Offsets JMA doesn't currently have a frame for are silently skipped.
  Future<List<JmaFrame>> getFrames() async {
    final results = await Future.wait([
      _fetchTimes(_observedUrl, observedOnly: true),
      _fetchTimes(_forecastUrl, observedOnly: false),
    ]);
    final observed = results[0], forecast = results[1];

    // Anchor "now" on the forecast basetime (the latest analysis); fall back
    // to the newest observed validtime if the forecast list is unavailable.
    final anchorStr = forecast.isNotEmpty
        ? forecast.first.basetime
        : observed.isNotEmpty
        ? observed.last.validtime
        : null;
    if (anchorStr == null) throw JmaException('no target times available');
    final anchor = parseJmaTime(anchorStr);

    final obsByValid = {for (final t in observed) t.validtime: t};
    final fcByValid = {for (final t in forecast) t.validtime: t};

    final out = <JmaFrame>[];
    for (final off in frameOffsetsMin) {
      final target = formatJmaTime(anchor.add(Duration(minutes: off)));
      // <=0 is observed/analysis (basetime==validtime); >0 is forecast.
      final t = off > 0 ? fcByValid[target] : obsByValid[target];
      if (t != null) {
        out.add(
          JmaFrame(
            basetime: t.basetime,
            validtime: t.validtime,
            offsetMin: off,
          ),
        );
      }
    }
    if (out.isEmpty) throw JmaException('no frames in target window');
    return out;
  }
}

/// JMA endpoint returned something unusable (bad status, empty index).
class JmaException implements Exception {
  final String message;
  JmaException(this.message);
  @override
  String toString() => 'JmaException: $message';
}
