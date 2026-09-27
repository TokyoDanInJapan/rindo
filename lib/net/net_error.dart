import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' show ClientException;

import 'tile_http_client.dart';

/// One place that answers 'does this error smell like lost connectivity?'.
///
/// Used by the offline heuristic, ConnectivityMonitor, and by the rider-facing
/// banner copy, MapBanners. Before this existed each kept its own marker list,
/// and the two had already drifted apart.
///
/// [isConnectivityError] decides by type where it has the error object, which
/// is the reliable way. The text markers remain for the errors that reach the
/// UI only as strings, the radar and closures banners, and for any wrapper
/// type that does not match below.
const _connectivityMarkers = [
  'SocketException',
  'ClientException',
  'HandshakeException',
  'No route to host',
  'Network is unreachable',
  'Failed host lookup',
  // dart:io's wordings for a connection lost part-way. A bare 'Connection'
  // also matched unrelated text, such as a server's 'Connection: close'.
  'Connection closed',
  'Connection refused',
  'Connection reset',
  'Connection timed out',
  'Connection failed',
  'Timeout',
];

bool looksLikeConnectivityError(String raw) =>
    _connectivityMarkers.any(raw.contains);

/// Type-first version of [looksLikeConnectivityError]. Socket, TLS and HTTP
/// transport failures are connectivity. So is a timeout, see [isTimeout] for
/// the callers that must tell those apart. Anything else falls back to the
/// text markers.
bool isConnectivityError(Object error) => switch (error) {
  SocketException() ||
  HandshakeException() ||
  ClientException() ||
  TileFetchException() ||
  TimeoutException() => true,
  _ => looksLikeConnectivityError('$error'),
};

/// A deadline ran out. The tile client's own deadline is congestion as often
/// as it is an outage, so the offline heuristic handles it apart.
bool isTimeout(Object error) =>
    error is TimeoutException || '$error'.contains('TimeoutException');
