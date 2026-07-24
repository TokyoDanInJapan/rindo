// Point thinning shared by the geometry generator scripts
// (fetch_gate_lines.dart, prep_japan_outline.dart).
import 'dart:math' as math;

/// Drop points closer than [minSpacingM] metres to the previously kept one;
/// endpoints always survive (which also preserves ring closure).
List<(double, double)> thinPoints(
    List<(double, double)> pts, double minSpacingM) {
  if (pts.length < 3) return pts;
  final out = [pts.first];
  for (var i = 1; i < pts.length - 1; i++) {
    if (distMeters(out.last, pts[i]) >= minSpacingM) out.add(pts[i]);
  }
  out.add(pts.last);
  return out;
}

/// Fast equirectangular distance - plenty at thinning scales.
double distMeters((double, double) a, (double, double) b) {
  const mPerDegLat = 111320.0;
  final mPerDegLon = mPerDegLat * math.cos(a.$1 * math.pi / 180);
  final dy = (a.$1 - b.$1) * mPerDegLat;
  final dx = (a.$2 - b.$2) * mPerDegLon;
  return math.sqrt(dx * dx + dy * dy);
}
