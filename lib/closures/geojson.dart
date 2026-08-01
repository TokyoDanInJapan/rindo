import 'package:latlong2/latlong.dart';

/// GeoJSON positions are `[lon, lat]`, per the spec. These helpers convert
/// defensively: a malformed entry is skipped, never thrown on, because the
/// upstream feeds are undocumented and drift.

/// A list of positions -> points. Entries that are not lists, that are too
/// short, or that hold the wrong types are dropped.
List<LatLng> latLngLine(dynamic positions) => [
  if (positions is List)
    for (final p in positions)
      if (p is List && p.length >= 2 && p[0] is num && p[1] is num)
        LatLng((p[1] as num).toDouble(), (p[0] as num).toDouble()),
];

/// A (Multi)LineString geometry -> its line(s). Anything else -> empty.
List<List<LatLng>> geometryLines(dynamic geometry) {
  if (geometry is! Map) return const [];
  final coords = geometry['coordinates'];
  if (coords is! List) return const [];
  return switch (geometry['type']) {
    'LineString' => [latLngLine(coords)],
    'MultiLineString' => [for (final part in coords) latLngLine(part)],
    _ => const [],
  };
}
