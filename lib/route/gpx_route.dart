import 'dart:isolate';

import 'package:latlong2/latlong.dart';
import 'package:xml/xml.dart';

/// GPX parsing and route geometry for 'closures along my planned ride'.
///
/// GPX is simple: `<trkpt lat=".." lon="..">` inside track segments, or
/// `<rtept>` for planned routes, or bare `<wpt>` waypoints. Files come from
/// route planners such as Komoot, RideWithGPS and Garmin, with wildly varying
/// point density, so consumers thin the points before any distance maths.

/// A loaded GPX file, ready for the map: [points] for the drawn track and the
/// corridor search, and [fit] for framing the camera.
typedef GpxRoute = ({List<LatLng> points, List<LatLng> fit});

/// Parse and thin a GPX file off the UI isolate. A planner export can hold
/// tens of thousands of points, and the XML parse plus a distance per point
/// is long enough to stall the map on the main isolate.
///
/// [points] keeps a point every 25 m, which is finer than the drawn line can
/// show at any zoom the map allows, and small enough that the map does not
/// simplify the full file on every repaint.
Future<GpxRoute> loadGpx(String content) => Isolate.run(() {
  final raw = parseGpx(content);
  return (points: thinRoute(raw, 0.025), fit: thinRoute(raw, 1));
});

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

/// Great-circle distance for filtering and thinning. Haversine is a few trig
/// calls against Vincenty's iteration, and its error, well under 1 %, is noise
/// against a 2 km spacing or a 10 km radius. Not rounded to the metre, so a
/// 25 m spacing stays exact.
const geoDistance = Distance(roundResult: false, calculator: Haversine());

/// Kilometres per degree of latitude, at its smallest (at the equator). A
/// latitude gap wider than the radius at this rate is outside it for certain.
const _kmPerDegreeLat = 110.57;

/// Drop points closer than [spacingKm] to the previously kept one. The
/// endpoints always survive. Planner exports can carry a point every few
/// metres, far denser than the closure-distance maths needs.
List<LatLng> thinRoute(List<LatLng> pts, double spacingKm) {
  if (pts.length < 3) return pts;
  final out = [pts.first];
  for (var i = 1; i < pts.length - 1; i++) {
    if (geoDistance.as(LengthUnit.Kilometer, out.last, pts[i]) >= spacingKm) {
      out.add(pts[i]);
    }
  }
  out.add(pts.last);
  return out;
}

/// Is [p] within [radiusKm] of any of [routePoints]? Callers pass a thinned
/// route. With about 2 km spacing the corridor edge wobbles by at most about
/// 1 km, which is noise against a 10 km scouting radius.
///
/// Runs once per closure per route vertex, so a vertex that is too far north
/// or south is skipped on the latitude alone before any trigonometry.
bool nearRoute(List<LatLng> routePoints, LatLng p, double radiusKm) {
  final maxDLat = radiusKm / _kmPerDegreeLat;
  for (final r in routePoints) {
    if ((r.latitude - p.latitude).abs() > maxDLat) continue;
    if (geoDistance.as(LengthUnit.Kilometer, r, p) <= radiusKm) return true;
  }
  return false;
}
