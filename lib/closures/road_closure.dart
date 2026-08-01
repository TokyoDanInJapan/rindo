import 'package:latlong2/latlong.dart';

/// Closure lifecycle relative to a point in time. Live-feed closures are
/// always [active]. Curated seasonal gates are [scheduled] until their closure
/// window opens.
enum ClosureStatus { active, scheduled }

/// One road restriction or closure, normalised from whichever upstream source
/// supplied it. Coordinates are mandatory, because the whole feature is 'what
/// is impassable within 50 km of me'.
class RoadClosure {
  final String id;
  final LatLng point;
  final String roadName; // such as '国道168号'
  final String? section; // such as '十津川村～新宮市'
  final String restriction; // such as '全面通行止' or '片側交互通行'
  final String? cause; // such as '土砂崩落', '災害' or '工事'
  final String? period; // human-readable regulation period, if provided
  final String sourceName; // attribution, such as 'JARTIC'
  final Uri sourceUrl; // link to the authoritative info page
  final List<List<LatLng>> lines; // regulated segment(s), for map overlay
  final DateTime? validFrom; // structured window start, when known
  final DateTime? validUntil; // structured window end, when known
  final bool isSeasonal; // recurring annual gate (nominal dates)

  /// Full closures block the road. Everything else, such as a lane
  /// restriction or alternating traffic, is passable but flagged. This is
  /// computed from the original Japanese restriction at construction, and
  /// translated display copies pass it through, so the styling survives
  /// translation.
  final bool isFullClosure;

  RoadClosure({
    required this.id,
    required this.point,
    required this.roadName,
    required this.restriction,
    required this.sourceName,
    required this.sourceUrl,
    this.section,
    this.cause,
    this.period,
    this.lines = const [],
    this.validFrom,
    this.validUntil,
    this.isSeasonal = false,
    bool? isFullClosure,
  }) : isFullClosure =
           isFullClosure ??
           (restriction.contains('通行止') && !restriction.contains('片側'));

  /// Live feeds report only what is closed now, so no [validFrom] means
  /// active. A future [validFrom] is an upcoming, seasonal window.
  ClosureStatus statusAt(DateTime now) =>
      validFrom != null && now.isBefore(validFrom!)
      ? ClosureStatus.scheduled
      : ClosureStatus.active;

  double distanceKmFrom(LatLng from) =>
      const Distance().as(LengthUnit.Kilometer, from, point);
}
