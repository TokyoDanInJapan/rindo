import 'package:flutter/material.dart';

/// Weather-code presentation, kept beside the closure equivalent in
/// closure_presentation.dart.
///
/// JMA tags every forecast period with a 3-digit 天気コード. It publishes about
/// 130 of them, each with its own telop image, but no machine-readable table.
/// The full mapping lives in the page's JavaScript. What *is* stable and
/// checkable is the leading digit, which names the family:
///
///   1xx 晴れ   2xx くもり   3xx 雨   4xx 雪
///
/// This was verified against live data from ten offices spread across the
/// country. All 87 of the 87 periods had a leading digit matching the first
/// word of JMA's own wording. (4xx could not be sampled in July. It is the
/// documented family, and the fallback below is harmless if it ever turns out
/// not to be.)
///
/// So the icon is deliberately coarse, one of four rather than one of 130.
/// JMA's wording sits next to it and carries everything the icon drops, such
/// as 夜のはじめ頃一時雨 and 所により雷を伴い激しく降る. An icon that tried to
/// encode that would be a worse version of the sentence already on screen.
IconData weatherIcon(String? code) => switch (code?.trim()) {
  final c? when c.startsWith('1') => Icons.sunny,
  final c? when c.startsWith('2') => Icons.cloud,
  final c? when c.startsWith('3') => Icons.water_drop,
  final c? when c.startsWith('4') => Icons.ac_unit,
  // The code is absent, as in the weekly table's first entries, or it is a
  // family JMA has not used before. Say nothing rather than guess.
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
