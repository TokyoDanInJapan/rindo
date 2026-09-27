import 'package:flutter_test/flutter_test.dart';
import 'package:rindo/translate/restriction_glossary.dart';

/// ML Kit renders 通行止 as 'Passing'. These pin the glossary that keeps the
/// one field a rider must not misread out of machine translation.

/// Stands in for ML Kit, with its real mistake.
Future<String> _machine(String ja) async => switch (ja) {
  '通行止' => 'Passing',
  _ => 'MT($ja)',
};

void main() {
  test('closures come out as closed, never as "Passing"', () async {
    for (final ja in ['通行止', '通行止め', '全面通行止', '全面 通行止め']) {
      expect(
        await restrictionInEnglish(ja, _machine),
        'Road closed',
        reason: ja,
      );
    }
  });

  test('the qualified closures keep their qualifier', () async {
    expect(await restrictionInEnglish('冬期通行止', _machine), 'Closed for winter');
    expect(await restrictionInEnglish('夜間通行止め', _machine), 'Closed at night');
    expect(
      await restrictionInEnglish('二輪車通行止', _machine),
      'Closed to motorcycles',
    );
  });

  test('passable restrictions and alerts use the glossary too', () async {
    expect(
      await restrictionInEnglish('片側交互通行', _machine),
      'Alternating one-way traffic',
    );
    expect(await restrictionInEnglish('土砂災害警戒情報', _machine), 'Landslide alert');
  });

  test('an unlisted closure is still marked closed', () async {
    expect(
      await restrictionInEnglish('橋梁点検通行止', _machine),
      'Road closed: MT(橋梁点検通行止)',
    );
  });

  test('an unlisted non-closure falls back to machine translation', () async {
    expect(await restrictionInEnglish('速度規制', _machine), 'MT(速度規制)');
  });
}
