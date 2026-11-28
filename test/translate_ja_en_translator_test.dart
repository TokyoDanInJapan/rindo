import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_translation/google_mlkit_translation.dart';
import 'package:latlong2/latlong.dart';
import 'package:rindo/closures/road_closure.dart';
import 'package:rindo/translate/ja_en_translator.dart';

/// Pins the translator's own behaviour, with ML Kit replaced by fakes: the
/// shared-future cache, its LRU bound, and what happens to work that is still
/// in flight when the translator is disposed.

/// Stands in for the platform channel. It records every call, and holds each
/// one until the test completes it when [manual] is set.
class _FakeMlKit extends Fake implements OnDeviceTranslator {
  _FakeMlKit({this.manual = false});

  final bool manual;
  final calls = <String>[];
  final pending = <String, Completer<String>>{};
  Object? failWith;
  bool closed = false;
  bool closeThrows = false;

  /// What the native side would do with a call that arrives after close: it
  /// builds a fresh translator that nothing closes.
  int callsAfterClose = 0;

  @override
  Future<String> translateText(String text) {
    calls.add(text);
    if (closed) callsAfterClose++;
    if (failWith != null) return Future.error(failWith!);
    if (!manual) return Future.value('EN:$text');
    return (pending[text] = Completer<String>()).future;
  }

  @override
  Future<void> close() {
    if (closeThrows) throw StateError('close blew up');
    closed = true;
    return Future.value();
  }
}

class _FakeModels extends Fake implements OnDeviceTranslatorModelManager {
  _FakeModels({this.gate});

  /// Holds the first isModelDownloaded until the test releases it.
  final Completer<void>? gate;
  int checks = 0;

  @override
  Future<bool> isModelDownloaded(String model) async {
    checks++;
    if (gate != null) await gate!.future;
    return true;
  }

  @override
  Future<bool> downloadModel(String model, {bool isWifiRequired = true}) =>
      Future.value(true);
}

RoadClosure _closure(int i) => RoadClosure(
  id: '$i',
  point: const LatLng(36, 138),
  roadName: '国道$i号',
  // Not in the glossary, so it goes to the machine like the other fields.
  restriction: '工事規制',
  sourceName: '道路情報提供システム',
  sourceUrl: Uri.parse('https://example.com'),
);

void main() {
  group('cache', () {
    test('concurrent identical requests share one platform call', () async {
      final kit = _FakeMlKit(manual: true);
      final t = JaEnTranslator(translator: kit, modelManager: _FakeModels());

      final all = Future.wait([
        for (var i = 0; i < 100; i++) t.translateText('通行止'),
      ]);
      expect(kit.calls, ['通行止']);
      kit.pending['通行止']!.complete('Closed');
      expect(await all, everyElement('Closed'));

      // Later requests are served from the cache too.
      expect(await t.translateText('通行止'), 'Closed');
      expect(kit.calls, hasLength(1));
      t.dispose();
    });

    test('100 closures fetched at once send each shared string once', () async {
      final kit = _FakeMlKit();
      final t = JaEnTranslator(translator: kit, modelManager: _FakeModels());

      final out = await Future.wait([
        for (var i = 0; i < 100; i++) t.translateClosure(_closure(i)),
      ]);

      expect(out.first.sourceName, 'EN:道路情報提供システム');
      expect(kit.calls.where((c) => c == '道路情報提供システム'), hasLength(1));
      expect(kit.calls.where((c) => c == '工事規制'), hasLength(1));
      // 100 distinct road names, plus the two shared strings.
      expect(kit.calls, hasLength(102));
      t.dispose();
    });

    test('a failed call returns the Japanese to every waiter, is not cached, '
        'and the next request retries', () async {
      final kit = _FakeMlKit()..failWith = Exception('model not ready');
      final t = JaEnTranslator(translator: kit, modelManager: _FakeModels());

      expect(
        await Future.wait([t.translateText('凍結'), t.translateText('凍結')]),
        ['凍結', '凍結'],
      );
      expect(kit.calls, hasLength(1));

      kit.failWith = null;
      expect(await t.translateText('凍結'), 'EN:凍結');
      expect(kit.calls, hasLength(2));
      t.dispose();
    });

    test('a synchronous throw from the plugin is contained as well', () async {
      final t = JaEnTranslator(
        translator: _ThrowingMlKit(),
        modelManager: _FakeModels(),
      );
      expect(await t.translateText('凍結'), '凍結');
      t.dispose();
    });

    test('is bounded: the least recently used string is evicted', () async {
      final kit = _FakeMlKit();
      final t = JaEnTranslator(
        translator: kit,
        modelManager: _FakeModels(),
        cacheLimit: 2,
      );
      await t.translateText('a');
      await t.translateText('b');
      await t.translateText('a'); // a is now the most recent
      await t.translateText('c'); // evicts b
      expect(kit.calls, ['a', 'b', 'c']);

      await t.translateText('a'); // still cached
      expect(kit.calls, ['a', 'b', 'c']);
      await t.translateText('b'); // was evicted, so it is fetched again
      expect(kit.calls, ['a', 'b', 'c', 'b']);
      t.dispose();
    });

    test('a failure does not drop a newer attempt that replaced it', () async {
      final kit = _FakeMlKit(manual: true);
      final t = JaEnTranslator(
        translator: kit,
        modelManager: _FakeModels(),
        cacheLimit: 1,
      );
      final first = t.translateText('a');
      final firstCall = kit.pending['a']!;
      unawaited(t.translateText('b')); // evicts the in-flight 'a'
      final second = t.translateText('a'); // a newer attempt, evicts 'b'
      final secondCall = kit.pending['a']!;

      firstCall.completeError(Exception('boom'));
      expect(await first, 'a');
      secondCall.complete('A');
      expect(await second, 'A');
      // The newer attempt's entry survived the older one's failure.
      expect(await t.translateText('a'), 'A');
      expect(kit.calls, ['a', 'b', 'a']);
      t.dispose();
    });
  });

  group('dispose', () {
    test('a model check that completes after dispose writes nothing and '
        'throws nothing', () async {
      final gate = Completer<void>();
      final t = JaEnTranslator(
        translator: _FakeMlKit(),
        modelManager: _FakeModels(gate: gate),
      );
      final ready = t.ensureReady();
      expect(t.status.value, TranslatorStatus.downloadingModel);

      t.dispose();
      gate.complete();
      // A write to the disposed notifier would fail this future in debug.
      expect(await ready, isFalse);
    });

    test('ensureReady after dispose starts no download', () async {
      final models = _FakeModels();
      final t = JaEnTranslator(translator: _FakeMlKit(), modelManager: models);
      t.dispose();
      expect(await t.ensureReady(), isFalse);
      expect(models.checks, 0);
    });

    test('nothing reaches the plugin after close, even from a closure that '
        'was half way through its fields', () async {
      final kit = _FakeMlKit(manual: true);
      final t = JaEnTranslator(translator: kit, modelManager: _FakeModels());
      final source = _closure(1);

      final translated = t.translateClosure(source);
      await pumpEventQueue();
      expect(kit.calls, ['国道1号'], reason: 'the first field is in flight');

      t.dispose();
      expect(kit.closed, isTrue);
      // The in-flight call fails natively once its translator is closed.
      kit.pending['国道1号']!.completeError(Exception('translator closed'));

      final out = await translated;
      expect(out.roadName, '国道1号');
      expect(out.sourceName, source.sourceName);
      expect(kit.callsAfterClose, 0);
      expect(await t.translateText('別'), '別');
      expect(kit.callsAfterClose, 0);
    });

    test('is idempotent, and a throwing close() is swallowed', () async {
      final kit = _FakeMlKit()..closeThrows = true;
      final t = JaEnTranslator(translator: kit, modelManager: _FakeModels());
      t.dispose();
      t.dispose();
      await pumpEventQueue();
    });
  });
}

class _ThrowingMlKit extends Fake implements OnDeviceTranslator {
  @override
  Future<String> translateText(String text) => throw StateError('sync');

  @override
  Future<void> close() => Future.value();
}
