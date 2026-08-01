import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Rider-facing warning about the limits of the data. The app shows it once at
/// first launch, and the rider must acknowledge it. It also stays readable
/// under the map credits (i). The app plots official feeds, but none of those
/// feeds is complete or real time. A rider who trusts a blank map is the
/// failure mode that matters.
const disclaimerText =
    'Road closure information can be late, incomplete or missing. The absence '
    'of a closure marker never means that a road is open. Radar frames after '
    '‘now’ are forecasts. Obey the road signs and the local authorities. Do '
    'not operate the app while you ride.';

// Versioned: bump this key if the wording changes enough that riders who
// accepted an old version must see it again.
const _seenKey = 'disclaimer-seen-v2';

/// First-launch warning. It shows [disclaimerText] once and blocks until the
/// rider acknowledges it. The app saves the flag only after the tap, so a
/// launch that dies while the dialogue is open shows it again next time.
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
