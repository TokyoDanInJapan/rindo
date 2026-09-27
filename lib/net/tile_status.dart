import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show NetworkImageLoadException;
import 'package:flutter_map/flutter_map.dart';

/// Tracks tiles that failed to load, per layer, so the UI can say how many
/// tiles failed and offer a retry, instead of leaving silent holes.
/// flutter_map reports failures through errorTileCallback but never retries by
/// itself. The retry is the screen's tile-epoch bump, which re-keys the
/// layers, and which also calls [reset] here.
class TileStatusMonitor extends ChangeNotifier {
  final Set<String> _failed = {};
  String? lastError;

  int get failedCount => _failed.length;
  bool get hasFailures => _failed.isNotEmpty;

  /// Record a failed tile. Radar layers 404 by design on rain-free tiles, so
  /// those are expected and never counted.
  void recordError(String layer, TileCoordinates coords, Object error) {
    if (_isNotFound(error)) return;
    final key = '$layer/${coords.z}/${coords.x}/${coords.y}';
    final added = _failed.add(key);
    lastError = '$error';
    if (added) notifyListeners();
  }

  static bool _isNotFound(Object error) => error is NetworkImageLoadException
      ? error.statusCode == 404
      // Kept for errors that arrive wrapped or stringified.
      : '$error'.contains('statusCode: 404');

  /// Forget everything. This is called when the tile layers are re-keyed, on a
  /// retry, on connectivity healing, or on replaced radar frames.
  void reset() {
    if (_failed.isEmpty) return;
    _failed.clear();
    notifyListeners();
  }
}
