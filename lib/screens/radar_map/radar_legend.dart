import 'package:flutter/material.dart';

import 'screen_margin.dart';

/// JMA's precipitation intensity scale (mm/h), for reading the radar.
class RadarLegend extends StatelessWidget {
  const RadarLegend({super.key});

  static const _steps = [
    (Color(0xFFF2F2FF), '0'),
    (Color(0xFFA0D2FF), '1'),
    (Color(0xFF218CFF), '5'),
    (Color(0xFF0041FF), '10'),
    (Color(0xFFFAF500), '20'),
    (Color(0xFFFF9900), '30'),
    (Color(0xFFFF2800), '50'),
    (Color(0xFFB40068), '80+'),
  ];

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.fromLTRB(screenMargin, 0, 0, screenMargin),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (color, label) in _steps)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 18,
                    height: 8,
                    color: color.withValues(alpha: 0.85),
                  ),
                  Text(label, style: const TextStyle(fontSize: 9)),
                ],
              ),
            const Padding(
              padding: EdgeInsets.only(left: 4),
              child: Text('mm/h', style: TextStyle(fontSize: 9)),
            ),
          ],
        ),
      ),
    );
  }
}
