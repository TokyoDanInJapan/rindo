import 'package:flutter/material.dart';

/// Weather-code presentation, kept beside the closure equivalent in
/// closure_presentation.dart.
///
/// JMA tags every forecast period with a 3-digit 天気コード. It publishes ~130
/// of them, each with its own telop image, but no machine-readable table - the
/// full mapping lives in the page's JavaScript. What *is* stable and checkable
/// is the leading digit, which names the family:
///
///   1xx 晴れ   2xx くもり   3xx 雨   4xx 雪
///
/// Verified against live data from ten offices spread across the country: 87
/// of 87 periods had a leading digit matching the first word of JMA's own
/// wording. (4xx couldn't be sampled in July; it's the documented family and
/// the fallback below is harmless if it ever isn't.)
///
/// So the icon is deliberately coarse - one of four, not one of 130 - and JMA's
/// wording sits next to it carrying everything the icon drops (夜のはじめ頃一時雨,
/// 所により雷を伴い激しく降る). An icon that tried to encode that would be a
/// worse version of the sentence already on screen.
IconData weatherIcon(String? code) => switch (code?.trim()) {
  final c? when c.startsWith('1') => Icons.sunny,
  final c? when c.startsWith('2') => Icons.cloud,
  final c? when c.startsWith('3') => Icons.water_drop,
  final c? when c.startsWith('4') => Icons.ac_unit,
  // Absent (the weekly table's first entries) or a family JMA hasn't used
  // before: say nothing rather than guess.
  _ => Icons.remove,
};

/// Colour matched to the icon, so a wet day reads as wet at a glance without
/// the rest of the sheet turning into a paint chart.
Color weatherColor(String? code, BuildContext context) =>
    switch (code?.trim()) {
      final c? when c.startsWith('1') => Colors.amber.shade700,
      final c? when c.startsWith('2') => Colors.blueGrey,
      final c? when c.startsWith('3') => Colors.blue.shade600,
      final c? when c.startsWith('4') => Colors.lightBlue.shade300,
      _ => Theme.of(context).disabledColor,
    };
