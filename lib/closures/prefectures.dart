/// GENERATED from dataofjapan/land japan.geojson: prefecture bounding boxes
/// (WGS84) plus JARTIC tile codes and MLIT bureau codes.
/// (The hand-written part is [prefecturesNear].)
library;

import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

// prefecturesAlong, for the route corridor, lives here next to
// prefecturesNear.

/// Prefectures whose bounding box intersects the search circle. The bounding
/// box is expanded by the radius, so a rider near a border pulls the
/// neighbouring prefecture too. A false positive costs one small tile fetch.
List<Prefecture> prefecturesNear(LatLng center, double radiusKm) {
  final dLat = radiusKm / 111.0;
  final dLon = radiusKm / (111.32 * math.cos(center.latitude * math.pi / 180));
  return [
    for (final p in prefectures)
      if (center.latitude >= p.minLat - dLat &&
          center.latitude <= p.maxLat + dLat &&
          center.longitude >= p.minLon - dLon &&
          center.longitude <= p.maxLon + dLon)
        p,
  ];
}

/// Union of [prefecturesNear] over the points of a thinned route: the tile set
/// that a route corridor needs.
List<Prefecture> prefecturesAlong(List<LatLng> route, double radiusKm) {
  final byCode = <String, Prefecture>{};
  for (final p in route) {
    for (final pref in prefecturesNear(p, radiusKm)) {
      byCode[pref.code] = pref;
    }
  }
  return byCode.values.toList();
}

/// One prefecture: JIS code, bounding box, and the MLIT bureaux whose feeds
/// cover it. The rows live in the generated [prefectures] table.
class Prefecture {
  final String code; // 2-digit JIS code, also JARTIC R-tile suffix
  final String name;
  final List<int> mlitBureaus; // 81..90 (some prefectures span two)
  final double minLat, minLon, maxLat, maxLon;
  const Prefecture(
    this.code,
    this.name,
    this.mlitBureaus,
    this.minLat,
    this.minLon,
    this.maxLat,
    this.maxLon,
  );
}

const prefectures = <Prefecture>[
  Prefecture('01', '北海道', [81], 41.3535, 139.3348, 45.5573, 148.8954),
  Prefecture('02', '青森県', [82], 40.2185, 139.4973, 41.5562, 141.6831),
  Prefecture('03', '岩手県', [82], 38.7484, 140.6541, 40.4509, 142.0726),
  Prefecture('04', '宮城県', [82], 37.7734, 140.2752, 39.0029, 141.6746),
  Prefecture('05', '秋田県', [82], 38.8741, 139.5203, 40.5115, 140.9958),
  Prefecture('06', '山形県', [82], 37.7343, 139.5393, 39.2085, 140.6463),
  Prefecture('07', '福島県', [82], 36.7918, 139.1648, 37.9769, 141.0433),
  Prefecture('08', '茨城県', [83], 35.7396, 139.6879, 36.9455, 140.8519),
  Prefecture('09', '栃木県', [83], 36.1998, 139.3273, 37.1550, 140.2926),
  Prefecture('10', '群馬県', [83], 35.9853, 138.3972, 37.0588, 139.6693),
  Prefecture('11', '埼玉県', [83], 35.7537, 138.7123, 36.2834, 139.9000),
  Prefecture('12', '千葉県', [83], 34.8995, 139.7394, 36.1041, 140.8709),
  Prefecture('13', '東京都', [83], 20.4227, 136.0695, 35.8981, 153.9869),
  Prefecture('14', '神奈川県', [83], 35.1287, 138.9162, 35.6721, 139.7963),
  Prefecture('15', '新潟県', [84], 36.7369, 137.6349, 38.5534, 139.9001),
  Prefecture('16', '富山県', [84], 36.2745, 136.7688, 36.9803, 137.7625),
  Prefecture('17', '石川県', [84], 36.0676, 136.2437, 37.8554, 137.3605),
  Prefecture('18', '福井県', [86], 35.3437, 135.4490, 36.2956, 136.8320),
  Prefecture('19', '山梨県', [83], 35.1685, 138.1803, 35.9717, 139.1343),
  Prefecture('20', '長野県', [83, 85], 35.1984, 137.3255, 37.0305, 138.7387),
  Prefecture('21', '岐阜県', [85], 35.1336, 136.2759, 36.4651, 137.6528),
  Prefecture('22', '静岡県', [85], 34.5946, 137.4748, 35.6460, 139.1756),
  Prefecture('23', '愛知県', [85], 34.5783, 136.6711, 35.4247, 137.8380),
  Prefecture('24', '三重県', [85], 33.7233, 135.8531, 35.2575, 136.9864),
  Prefecture('25', '滋賀県', [86], 34.7907, 135.7637, 35.7037, 136.4543),
  Prefecture('26', '京都府', [86], 34.7059, 134.8542, 35.7792, 136.0552),
  Prefecture('27', '大阪府', [86], 34.2720, 135.0931, 35.0509, 135.7454),
  Prefecture('28', '兵庫県', [86], 34.1565, 134.2531, 35.6747, 135.4671),
  Prefecture('29', '奈良県', [85, 86], 33.8588, 135.5396, 34.7813, 136.2290),
  Prefecture('30', '和歌山県', [86], 33.4333, 134.9987, 34.3844, 136.0129),
  Prefecture('31', '鳥取県', [87], 35.0578, 133.1357, 35.6146, 134.5146),
  Prefecture('32', '島根県', [87], 34.3025, 131.6672, 37.2478, 133.3853),
  Prefecture('33', '岡山県', [87], 34.2984, 133.2667, 35.3528, 134.4120),
  Prefecture('34', '広島県', [87], 34.0353, 132.0359, 35.1057, 133.4697),
  Prefecture('35', '山口県', [87], 33.7131, 130.7742, 34.7983, 132.4910),
  Prefecture('36', '徳島県', [88], 33.5397, 133.6602, 34.2515, 134.8212),
  Prefecture('37', '香川県', [88], 34.0124, 133.4516, 34.5643, 134.4397),
  Prefecture('38', '愛媛県', [88], 32.8981, 132.0119, 34.2993, 133.6920),
  Prefecture('39', '高知県', [88], 32.7023, 132.4794, 33.8830, 134.3125),
  Prefecture('40', '福岡県', [89], 33.0005, 130.0325, 34.2493, 131.1891),
  Prefecture('41', '佐賀県', [89], 32.9505, 129.7394, 33.6183, 130.5410),
  Prefecture('42', '長崎県', [89], 31.9864, 128.1045, 34.7245, 130.3773),
  Prefecture('43', '熊本県', [89], 32.0949, 129.9632, 33.1947, 131.3286),
  Prefecture('44', '大分県', [89], 32.7149, 130.8240, 33.7398, 132.0846),
  Prefecture('45', '宮崎県', [89], 31.3607, 130.7025, 32.8385, 131.8851),
  Prefecture('46', '鹿児島県', [89], 27.0186, 128.3944, 32.3067, 131.2038),
  Prefecture('47', '沖縄県', [90], 24.0447, 122.9335, 27.8847, 131.3323),
];
