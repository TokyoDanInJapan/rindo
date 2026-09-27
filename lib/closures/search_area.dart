import 'package:latlong2/latlong.dart';

import '../route/gpx_route.dart';
import 'prefectures.dart';

/// Where the closure sources look: a circle around the rider or a pin, or a
/// corridor along a loaded route.
///
/// Every source asks the same two questions of it: which prefecture feeds to
/// fetch, and whether a point is inside. The circle-or-corridor branching
/// lives here once, instead of in a pair of fetch methods per source.
sealed class SearchArea {
  const SearchArea();

  /// Prefectures whose feeds can hold a point inside the area.
  List<Prefecture> get prefectures;

  bool contains(LatLng p);
}

/// Everything within [radiusKm] of [center].
final class CircleArea extends SearchArea {
  CircleArea(this.center, this.radiusKm);

  final LatLng center;
  final double radiusKm;

  @override
  late final List<Prefecture> prefectures = prefecturesNear(center, radiusKm);

  @override
  bool contains(LatLng p) =>
      geoDistance.as(LengthUnit.Kilometer, center, p) <= radiusKm;
}

/// Everything within [radiusKm] of any point of a route.
///
/// Build it once per loaded route, not once per fetch: it thins the route and
/// works out the prefectures, and both walk the whole track.
final class CorridorArea extends SearchArea {
  CorridorArea(List<LatLng> route, this.radiusKm)
    // A spacing of about 2 km keeps the corridor test cheap. The edge wobble
    // that introduces is noise against a 10 km scouting radius.
    : points = thinRoute(route, 2);

  /// The thinned route that [contains] measures from.
  final List<LatLng> points;
  final double radiusKm;

  @override
  late final List<Prefecture> prefectures = prefecturesAlong(points, radiusKm);

  @override
  bool contains(LatLng p) => nearRoute(points, p, radiusKm);
}
