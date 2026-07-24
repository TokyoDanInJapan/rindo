import 'package:flutter/foundation.dart';
import 'package:flutter_map/flutter_map.dart';

/// Tracks tiles that failed to load, per layer, so the UI can say "N tiles
/// failed - tap to retry" instead of leaving silent holes. flutter_map
/// reports failures via errorTileCallback but never retries by itself; the
/// retry is the screen's tile-epoch bump (re-keying the layers), which
/// also calls [reset] here.
class TileStatusMonitor extends ChangeNotifier {
  final Set<String> _failed = {};
  String? lastError;

  int get failedCount => _failed.length;
  bool get hasFailures => _failed.isNotEmpty;

  /// Record a failed tile. Radar layers 404 by design on rain-free tiles -
  /// those are expected and never counted.
  void recordError(String layer, TileCoordinates coords, Object error) {
    if ('$error'.contains('statusCode: 404')) return;
    final key = '$layer/${coords.z}/${coords.x}/${coords.y}';
    final added = _failed.add(key);
    lastError = '$error';
    if (added) notifyListeners();
  }

  /// Forget everything - called when the tile layers are re-keyed (retry,
  /// connectivity healed, radar frames replaced).
  void reset() {
    if (_failed.isEmpty) return;
    _failed.clear();
    notifyListeners();
  }
}
