import 'dart:async';

import 'package:flutter/material.dart';

import 'screen_margin.dart';

/// Banner for the one-time translation-model download: an indeterminate bar
/// plus a live elapsed-time counter. ML Kit's downloadModel exposes no byte
/// progress, so this is as honest as a 'progress bar' can get. It shows motion
/// and elapsed time, not a made-up percentage.
class ModelDownloadBanner extends StatefulWidget {
  final DateTime startedAt;

  const ModelDownloadBanner({super.key, required this.startedAt});

  @override
  State<ModelDownloadBanner> createState() => _ModelDownloadBannerState();
}

class _ModelDownloadBannerState extends State<ModelDownloadBanner> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final elapsed = DateTime.now().difference(widget.startedAt).inSeconds;
    return Card(
      // Informational, not an error, so it is styled apart from the error
      // banners.
      color: scheme.secondaryContainer,
      margin: const EdgeInsets.fromLTRB(screenMargin, 4, screenMargin, 0),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Downloading the offline translation model '
              '(about 60 MB, one time)… ${elapsed}s',
              style: TextStyle(color: scheme.onSecondaryContainer),
            ),
            const SizedBox(height: 8),
            const ClipRRect(
              borderRadius: BorderRadius.all(Radius.circular(2)),
              child: LinearProgressIndicator(minHeight: 4),
            ),
          ],
        ),
      ),
    );
  }
}
