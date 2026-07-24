import 'package:http/http.dart';

/// For client wrappers that guard or tap a response body (the tile client's
/// stall deadline, the asset monitor's byte counter): same response, new
/// body stream, every other field carried over verbatim.
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
