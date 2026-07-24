import 'package:flutter/material.dart';

import '../../jma/jma_api.dart';
import '../../net/asset_monitor.dart';
import 'screen_margin.dart';

/// The radar timeline: play/pause, a frame scrubber with a per-frame
/// load-state dot beneath each stop, and the active frame's JST time +
/// offset label (or a spinner while the frame index loads).
class FrameControls extends StatelessWidget {
  final List<JmaFrame> frames;
  final int frameIndex;

  /// Parallel to [frames]: whether each frame's tiles have arrived.
  final List<FrameLoadState> frameStatus;
  final bool playing;
  final VoidCallback onPlayPause;
  final ValueChanged<int> onSeek; // also pauses playback

  const FrameControls({
    super.key,
    required this.frames,
    required this.frameIndex,
    required this.frameStatus,
    required this.playing,
    required this.onPlayPause,
    required this.onSeek,
  });

  static Color statusColor(FrameLoadState s) => switch (s) {
    FrameLoadState.pending => Colors.grey.shade400,
    FrameLoadState.loading => Colors.amber.shade600,
    FrameLoadState.loaded => Colors.green.shade600,
    FrameLoadState.failed => Colors.red.shade600,
  };

  @override
  Widget build(BuildContext context) {
    final frame = frames.isEmpty ? null : frames[frameIndex];
    return Card(
      margin: const EdgeInsets.fromLTRB(
        screenMargin,
        screenMargin,
        screenMargin,
        0,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: [
            IconButton(
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
              onPressed: frames.isEmpty ? null : onPlayPause,
            ),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Slider(
                    value: frameIndex.toDouble(),
                    max: (frames.length - 1).clamp(1, 99).toDouble(),
                    divisions: (frames.length - 1).clamp(1, 99),
                    onChanged: frames.isEmpty ? null : (v) => onSeek(v.round()),
                  ),
                  // One dot per frame, coloured by tile load state, so a
                  // frame whose radar imagery is missing (still loading, or
                  // failed) is visible at a glance. spaceBetween roughly
                  // lines the dots up with the slider stops.
                  if (frames.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          for (var i = 0; i < frames.length; i++)
                            Container(
                              key: ValueKey('frame-dot-$i'),
                              width: i == frameIndex ? 10 : 7,
                              height: i == frameIndex ? 10 : 7,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: statusColor(
                                  i < frameStatus.length
                                      ? frameStatus[i]
                                      : FrameLoadState.pending,
                                ),
                                border: i == frameIndex
                                    ? Border.all(
                                        color: Colors.blueGrey.shade700,
                                      )
                                    : null,
                              ),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (frame != null)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${frame.jstLabel} JST',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    Text(
                      frame.isForecast
                          ? 'forecast ${frame.offsetLabel}'
                          : frame.offsetLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: frame.isForecast
                            ? Colors.deepOrange
                            : Colors.green.shade700,
                      ),
                    ),
                  ],
                ),
              )
            else
              const Padding(
                padding: EdgeInsets.all(12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
