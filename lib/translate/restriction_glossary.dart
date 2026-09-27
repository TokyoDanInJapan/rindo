/// Fixed English for the restriction terms the closure feeds use.
///
/// The restriction is the one field a rider must never misread, and machine
/// translation gets it badly wrong. ML Kit renders 通行止 ('no through
/// traffic', the road is closed) as 'Passing', which says close to the
/// opposite. These terms are a short, closed set from JARTIC, MLIT, the
/// seasonal gates and JMA, so they are looked up here and never guessed.
///
/// Keys are normalised by [_normalise]: no spaces, and 通行止め spelt 通行止.
const _glossary = <String, String>{
  // Full closures.
  '通行止': 'Road closed',
  '全面通行止': 'Road closed',
  '冬期通行止': 'Closed for winter',
  '冬季通行止': 'Closed for winter',
  '冬期閉鎖': 'Closed for winter',
  '夜間通行止': 'Closed at night',
  '時間通行止': 'Closed at set times',
  '時間帯通行止': 'Closed at set times',
  '災害通行止': 'Closed (disaster)',
  '雨量規制通行止': 'Closed (rainfall limit)',
  '事前通行規制': 'Closed ahead of heavy rain',
  // Closed to some vehicles only.
  '二輪車通行止': 'Closed to motorcycles',
  '自動二輪車通行止': 'Closed to motorcycles',
  '大型車通行止': 'Closed to large vehicles',
  '車両通行止': 'Closed to vehicles',
  '歩行者通行止': 'Closed to pedestrians',
  // Passable, but restricted.
  '片側交互通行': 'Alternating one-way traffic',
  '片側通行': 'One lane open',
  '片側規制': 'One lane closed',
  '車線規制': 'Lane closure',
  '２車線規制': 'Two lanes closed',
  '2車線規制': 'Two lanes closed',
  'チェーン規制': 'Snow chains required',
  'その他規制': 'Other restriction',
  // Hazard alerts, which ride the same list.
  '土砂災害警戒情報': 'Landslide alert',
};

String _normalise(String ja) =>
    ja.replaceAll(RegExp(r'[\s　]'), '').replaceAll('通行止め', '通行止');

/// English for the restriction [ja], from the glossary where it has the term.
///
/// A term it lacks goes to [translate], the machine translation. A term that
/// still says 通行止 is then prefixed 'Road closed', so an unlisted closure
/// can never come out reading as passable.
Future<String> restrictionInEnglish(
  String ja,
  Future<String> Function(String) translate,
) async {
  final known = _glossary[_normalise(ja)];
  if (known != null) return known;
  final machine = await translate(ja);
  return ja.contains('通行止') ? 'Road closed: $machine' : machine;
}
