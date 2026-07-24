import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:rindo/route/gpx_route.dart';

const _track = '''
<?xml version="1.0"?>
<gpx version="1.1" creator="test">
  <trk><name>ride</name><trkseg>
    <trkpt lat="35.45" lon="139.55"><ele>10</ele></trkpt>
    <trkpt lat="35.50" lon="139.60"/>
    <trkpt lat="35.55" lon="139.65"/>
  </trkseg></trk>
</gpx>''';

void main() {
  group('parseGpx', () {
    test('reads track points in order', () {
      final pts = parseGpx(_track);
      expect(pts, hasLength(3));
      expect(pts.first, const LatLng(35.45, 139.55));
      expect(pts.last, const LatLng(35.55, 139.65));
    });

    test('falls back track > route > waypoint', () {
      final rte = parseGpx(
        '<gpx><rte>'
        '<rtept lat="36.0" lon="138.0"/><rtept lat="36.1" lon="138.1"/>'
        '</rte></gpx>',
      );
      expect(rte, hasLength(2));
      final wpt = parseGpx('<gpx><wpt lat="36.0" lon="138.0"/></gpx>');
      expect(wpt, hasLength(1));
    });

    test('rejects non-GPX and empty documents', () {
      expect(() => parseGpx('<kml></kml>'), throwsFormatException);
      expect(() => parseGpx('not xml at all <'), throwsFormatException);
      expect(() => parseGpx('<gpx></gpx>'), throwsFormatException);
    });

    test('skips points with missing or out-of-range coordinates', () {
      final pts = parseGpx(
        '<gpx><trk><trkseg>'
        '<trkpt lat="35.0" lon="139.0"/>'
        '<trkpt lat="abc" lon="139.0"/>' // unparseable
        '<trkpt lon="139.0"/>' // no lat
        '<trkpt lat="120.0" lon="139.0"/>' // lat out of range
        '</trkseg></trk></gpx>',
      );
      expect(pts, hasLength(1));
    });
  });

  group('thinRoute', () {
    test('drops points closer than the spacing but keeps the ends', () {
      // ~1.1 km per 0.01° lat; 5 points at 0.005° ≈ 550 m apart.
      final dense = [
        for (var i = 0; i < 5; i++) LatLng(35.0 + i * 0.005, 139.0),
      ];
      final thinned = thinRoute(dense, 2); // 2 km spacing
      expect(thinned.length, lessThan(dense.length));
      expect(thinned.first, dense.first);
      expect(thinned.last, dense.last);
    });
  });

  group('nearRoute', () {
    final route = [const LatLng(35.0, 139.0), const LatLng(35.5, 139.0)];
    test('true within radius of some vertex, false beyond', () {
      expect(nearRoute(route, const LatLng(35.02, 139.0), 10), isTrue);
      expect(nearRoute(route, const LatLng(36.5, 139.0), 10), isFalse);
    });
  });
}
