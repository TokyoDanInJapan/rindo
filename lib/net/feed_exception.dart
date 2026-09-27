/// An upstream data feed (JMA, JARTIC or MLIT) answered with something
/// unusable, or not at all. [source] names the feed, so a failure can say
/// which one is missing without the caller having to parse the text.
class FeedException implements Exception {
  FeedException(this.source, this.message);

  final String source;
  final String message;

  @override
  String toString() => '$source: $message';
}
