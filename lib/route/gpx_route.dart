import 'package:latlong2/latlong.dart';
import 'package:xml/xml.dart';

/// GPX parsing and route geometry for 'closures along my planned ride'.
///
/// GPX is simple: `<trkpt lat=".." lon="..">` inside track segments, or
/// `<rtept>` for planned routes, or bare `<wpt>` waypoints. Files come from
/// route planners such as Komoot, RideWithGPS and Garmin, with wildly varying
/// point density, so consumers thin the points before any distance maths.

/// Points of the first non-empty kind found: track > route > waypoints.
/// Throws [FormatException] when the document is not GPX, or has no points.
List<LatLng> parseGpx(String content) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(content);
  } on XmlException catch (e) {
    throw FormatException('not valid XML: ${e.message}');
  }
  if (doc.rootElement.name.local != 'gpx') {
    throw const FormatException('not a GPX document');
  }
  for (final tag in ['trkpt', 'rtept', 'wpt']) {
    final pts = <LatLng>[
      for (final el in doc.rootElement.findAllElements(tag)) ?_point(el),
    ];
    if (pts.isNotEmpty) return pts;
  }
  throw const FormatException('GPX contains no points');
}

LatLng? _point(XmlElement el) {
  final lat = double.tryParse(el.getAttribute('lat') ?? '');
  final lon = double.tryParse(el.getAttribute('lon') ?? '');
  if (lat == null || lon == null) return null;
  if (lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
  return LatLng(lat, lon);
}

/// Drop points closer than [spacingKm] to the previously kept one. The
/// endpoints always survive. Planner exports can carry a point every few
/// metres, far denser than the closure-distance maths needs.
List<LatLng> thinRoute(List<LatLng> pts, double spacingKm) {
  if (pts.length < 3) return pts;
  const dist = Distance();
  final out = [pts.first];
  for (var i = 1; i < pts.length - 1; i++) {
    if (dist.as(LengthUnit.Kilometer, out.last, pts[i]) >= spacingKm) {
      out.add(pts[i]);
    }
  }
  out.add(pts.last);
  return out;
}

/// Is [p] within [radiusKm] of any of [routePoints]? Callers pass a thinned
/// route. With about 2 km spacing the corridor edge wobbles by at most about
/// 1 km, which is noise against a 10 km scouting radius.
bool nearRoute(List<LatLng> routePoints, LatLng p, double radiusKm) {
  const dist = Distance();
  return routePoints.any(
    (r) => dist.as(LengthUnit.Kilometer, r, p) <= radiusKm,
  );
}
