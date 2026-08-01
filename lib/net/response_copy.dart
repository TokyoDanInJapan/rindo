import 'package:http/http.dart';

/// For client wrappers that guard or tap a response body, such as the tile
/// client's stall deadline and the asset monitor's byte counter. It gives the
/// same response with a new body stream, and carries every other field over
/// unchanged.
extension StreamedResponseCopy on StreamedResponse {
  StreamedResponse copyWithStream(Stream<List<int>> stream) => StreamedResponse(
    stream,
    statusCode,
    contentLength: contentLength,
    request: request,
    headers: headers,
    isRedirect: isRedirect,
    persistentConnection: persistentConnection,
    reasonPhrase: reasonPhrase,
  );
}
