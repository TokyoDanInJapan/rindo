import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'screen_margin.dart';

/// A compass button that appears while the map is turned away from north.
///
/// The needle tracks the map's north as the map rotates, because it gets the
/// same transform that flutter_map applies to the map itself. Tapping it snaps
/// the map back to north-up. When the map is already north-aligned there is
/// nothing to correct, so the button hides itself, as it does in Google Maps
/// and Apple Maps. Rotate the map with a two-finger twist to bring it out.
class MapCompass extends StatelessWidget {
  /// Map rotation in degrees, from flutter_map's camera, where 0 is north-up.
  final double rotationDeg;

  /// Tapped, so the screen resets the map to north.
  final VoidCallback onFaceNorth;

  const MapCompass({
    super.key,
    required this.rotationDeg,
    required this.onFaceNorth,
  });

  /// How far off north [deg] is, folded into 0..180, so 359° reads as 1° off.
  static double offNorth(double deg) {
    final norm = (deg % 360 + 360) % 360;
    return norm > 180 ? 360 - norm : norm;
  }

  @override
  Widget build(BuildContext context) {
    // Within a degree of north there is nothing to reset, so show nothing.
    if (offNorth(rotationDeg) < 1) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Padding(
      // The top 8 is spacing below the banners. The right edge takes the
      // shared screen margin, so that the compass lines up with the button
      // column below it.
      padding: const EdgeInsets.only(top: 8, right: screenMargin),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.small(
            heroTag: 'compass',
            tooltip: 'Face north',
            backgroundColor: scheme.surface,
            foregroundColor: scheme.onSurface,
            onPressed: onFaceNorth,
            // The same transform flutter_map applies to the map itself, a
            // Transform.rotate by the camera's rotationRad, so the red N tip
            // always points along the map's north on screen.
            child: Transform.rotate(
              angle: rotationDeg * math.pi / 180,
              child: CustomPaint(
                size: const Size(22, 22),
                painter: _NeedlePainter(
                  north: Colors.red.shade600,
                  south: scheme.onSurface.withValues(alpha: 0.45),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A two-tone diamond needle: the red half points north, the muted half south.
class _NeedlePainter extends CustomPainter {
  final Color north;
  final Color south;
  const _NeedlePainter({required this.north, required this.south});

  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final waist = size.width * 0.18;
    final left = Offset(cx - waist, cy);
    final right = Offset(cx + waist, cy);

    void half(Offset tip, Color color) {
      final path = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(left.dx, left.dy)
        ..lineTo(right.dx, right.dy)
        ..close();
      canvas.drawPath(path, Paint()..color = color);
    }

    half(Offset(cx, 0), north); // N
    half(Offset(cx, size.height), south); // S
  }

  @override
  bool shouldRepaint(_NeedlePainter old) =>
      old.north != north || old.south != south;
}
