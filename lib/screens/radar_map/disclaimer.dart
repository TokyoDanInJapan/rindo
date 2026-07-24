import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Rider-facing warning about the limits of the data. Shown once at first
/// launch (acknowledged explicitly) and permanently readable under the
/// map-credits (i) - the app plots official feeds, but none of them are
/// complete or real-time, and a rider trusting a blank map is the failure
/// mode that matters.
const disclaimerText =
    'Road closure information may be delayed, incomplete, or missing - the '
    'absence of a closure marker never means a road is open. Radar frames '
    'after “now” are forecasts. Obey signage and local authorities, and '
    'don’t operate the app while riding.';

// Versioned: bump if the wording changes enough that riders who accepted an
// old version should see it again.
const _seenKey = 'disclaimer-seen-v1';

/// First-launch warning: shows [disclaimerText] once, blocking until the
/// rider explicitly acknowledges it. The flag is only persisted after the
/// tap, so a launch that dies mid-dialog shows it again next time.
Future<void> showFirstRunDisclaimer(BuildContext context) async {
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(_seenKey) ?? false) return;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Before you ride'),
      content: const Text(disclaimerText),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('I understand'),
        ),
      ],
    ),
  );
  await prefs.setBool(_seenKey, true);
}
