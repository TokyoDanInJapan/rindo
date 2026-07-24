/// One place that answers "does this error smell like lost connectivity?".
///
/// Errors reach the UI as strings (tile error callbacks and feed fetches
/// stringify them), so the classification is textual. Used by the offline
/// heuristic (ConnectivityMonitor) and the rider-facing banner copy
/// (MapBanners); before this existed each kept its own marker list and they
/// had already drifted apart.
const _connectivityMarkers = [
  'SocketException',
  'ClientException',
  'HandshakeException',
  'No route to host',
  'Network is unreachable',
  'Failed host lookup',
  'Connection',
  'Timeout',
];

bool looksLikeConnectivityError(String raw) =>
    _connectivityMarkers.any(raw.contains);
