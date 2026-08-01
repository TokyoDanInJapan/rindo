/// One place that answers 'does this error smell like lost connectivity?'.
///
/// Errors reach the UI as strings, because the tile error callbacks and the
/// feed fetches stringify them, so the classification works on text. It is
/// used by the offline heuristic, ConnectivityMonitor, and by the rider-facing
/// banner copy, MapBanners. Before this existed each kept its own marker list,
/// and the two had already drifted apart.
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
