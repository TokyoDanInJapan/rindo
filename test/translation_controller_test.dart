import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:rindo/closures/road_closure.dart';
import 'package:rindo/translate/ja_en_translator.dart';
import 'package:rindo/translate/translation_controller.dart';

/// Pins the language/translation state machine on its own: the originals-
/// first swap-in, the superseded-fetch rule, and the toggle behavior.

RoadClosure _closure(String road) => RoadClosure(
  id: road,
  point: const LatLng(36, 138),
  roadName: road,
  restriction: '通行止',
  sourceName: 'src',
  sourceUrl: Uri.parse('https://example.com'),
);

/// Deterministic, no platform channels: "translates" by prefixing. A gate
/// (when provided) holds every translation until the test releases it.
class _FakeTranslator extends JaEnTranslator {
  _FakeTranslator({this.gate, this.fail = false});

  final Completer<void>? gate;
  final bool fail;

  @override
  Future<bool> ensureReady() async => true;

  @override
  Future<RoadClosure> translateClosure(RoadClosure c) async {
    if (gate != null) await gate!.future;
    if (fail) throw StateError('translator blew up');
    return RoadClosure(
      id: c.id,
      point: c.point,
      roadName: 'EN:${c.roadName}',
      restriction: c.restriction,
      sourceName: c.sourceName,
      sourceUrl: c.sourceUrl,
      isFullClosure: c.isFullClosure,
    );
  }
}

void main() {
  test('Japanese mode shows originals and never starts a translation', () {
    final t = TranslationController(
      translator: _FakeTranslator(),
      english: false,
    );
    t.setSource([_closure('国道1号')]);
    expect(t.shown.single.roadName, '国道1号');
    expect(t.translating, isFalse);
    t.dispose();
  });

  test('English mode shows originals immediately, then swaps in the '
      'translation', () async {
    final t = TranslationController(
      translator: _FakeTranslator(),
      english: true,
    );
    t.setSource([_closure('国道1号')]);
    // Synchronously after setSource: originals, translation in flight.
    expect(t.shown.single.roadName, '国道1号');
    expect(t.translating, isTrue);
    await pumpEventQueue();
    expect(t.shown.single.roadName, 'EN:国道1号');
    expect(t.translating, isFalse);
    t.dispose();
  });

  test('toggling to English translates the current list; toggling back '
      'shows originals untouched', () async {
    final t = TranslationController(
      translator: _FakeTranslator(),
      english: false,
    );
    t.setSource([_closure('県道84号')]);
    await pumpEventQueue();
    expect(t.shown.single.roadName, '県道84号');

    t.toggleLanguage();
    await pumpEventQueue();
    expect(t.english, isTrue);
    expect(t.shown.single.roadName, 'EN:県道84号');

    t.toggleLanguage();
    expect(t.english, isFalse);
    expect(t.shown.single.roadName, '県道84号');
    t.dispose();
  });

  test(
    'a slow translation of an old fetch never overwrites a newer list',
    () async {
      final gate = Completer<void>();
      final t = TranslationController(
        translator: _FakeTranslator(gate: gate),
        english: true,
      );
      t.setSource([_closure('old')]);
      // A newer fetch supersedes the source while the first translation is
      // still stuck behind the gate.
      t.setSource([_closure('new')]);
      gate.complete();
      await pumpEventQueue();
      // Both translations finished, but only the current source's result may
      // land - 'EN:old' must not have clobbered the newer list.
      expect(t.shown.single.roadName, 'EN:new');
      t.dispose();
    },
  );

  test('notifies listeners on the English swap-in', () async {
    final t = TranslationController(
      translator: _FakeTranslator(),
      english: true,
    );
    var notifications = 0;
    t.addListener(() => notifications++);
    t.setSource([_closure('x')]);
    final before = notifications;
    await pumpEventQueue();
    expect(notifications, greaterThan(before));
    t.dispose();
  });

  test('the translating flag holds until the last overlapping translation '
      'lands', () async {
    final first = Completer<void>();
    final t = TranslationController(
      translator: _FakeTranslator(gate: first),
      english: true,
    );
    t.setSource([_closure('国道1号')]); // held by the gate
    t.toggleLanguage();
    t.toggleLanguage(); // English again: a second translation starts
    expect(t.translating, isTrue);
    first.complete();
    await pumpEventQueue();
    expect(t.translating, isFalse);
    expect(t.shown.single.roadName, 'EN:国道1号');
    t.dispose();
  });

  test('a translation that lands after dispose neither notifies nor '
      'throws', () async {
    final gate = Completer<void>();
    final t = TranslationController(
      translator: _FakeTranslator(gate: gate),
      english: true,
    );
    var notifications = 0;
    t.addListener(() => notifications++);
    t.setSource([_closure('国道1号')]);
    final before = notifications;

    t.dispose();
    gate.complete();
    // An unhandled async error here would fail the test.
    await pumpEventQueue();
    expect(notifications, before);
  });

  // A download that lands after dispose is covered in
  // translate_ja_en_translator_test.dart, against the real translator class.
  test('dispose disposes the translator once, and twice is harmless', () async {
    final translator = _FakeTranslator();
    final t = TranslationController(translator: translator, english: false);
    t.dispose();
    // A disposed translator answers with the original and sends nothing.
    expect(await translator.translateText('x'), 'x');
    t.dispose();
  });

  test('a translator that throws leaves the originals on screen and no '
      'unhandled error', () async {
    final t = TranslationController(
      translator: _FakeTranslator(fail: true),
      english: true,
    );
    t.setSource([_closure('国道1号')]);
    await pumpEventQueue();
    expect(t.shown.single.roadName, '国道1号');
    expect(t.translating, isFalse);
    t.dispose();
  });
}
