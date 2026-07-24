// Live smoke test of the data layer against the real JMA / JARTIC / MLIT
// services. Not part of the test suite (it needs the network):
//   dart run tool/live_check.dart [lat lon]
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:latlong2/latlong.dart';
import 'package:rindo/closures/closure_repository.dart';
import 'package:rindo/jma/jma_api.dart';

Future<void> main(List<String> args) async {
  final center = args.length >= 2
      ? LatLng(double.parse(args[0]), double.parse(args[1]))
      : const LatLng(35.45, 139.55); // Yokohama-ish

  print('== JMA nowcast frames ==');
  final frames = await JmaApi().getFrames();
  for (final f in frames) {
    print('  ${f.jstLabel} JST ${f.offsetLabel.padLeft(4)}  '
        'base=${f.basetime} valid=${f.validtime}');
  }
  print('  tile template: ${frames.first.urlTemplate}');

  print('== Road closures within 50 km of $center ==');
  final (closures, errors) = await ClosureRepository().fetchNear(center, 50);
  for (final e in errors) {
    print('  SOURCE FAILED: $e');
  }
  closures.sort(
      (a, b) => a.distanceKmFrom(center).compareTo(b.distanceKmFrom(center)));
  for (final c in closures) {
    print('  ${c.distanceKmFrom(center).toStringAsFixed(1).padLeft(5)} km  '
        '${c.roadName} ${c.restriction}'
        '${c.cause != null ? '（${c.cause}）' : ''}  '
        '[${c.sourceName}] lines=${c.lines.length}');
    print('         ${c.section ?? ''} -> ${c.sourceUrl}');
  }
  print('${closures.length} closures');
  exit(0);
}
