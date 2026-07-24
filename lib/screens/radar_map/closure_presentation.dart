import 'package:flutter/material.dart';

import '../../closures/road_closure.dart';

/// Shared closure styling: the map markers, list rows and detail sheet must
/// agree on what a closure looks like.

/// Snowflake for seasonal gates, block/warning for live closures.
IconData closureIcon(RoadClosure c) => c.isSeasonal
    ? Icons.ac_unit
    : c.isFullClosure
    ? Icons.block
    : Icons.warning_amber_rounded;

/// Indigo while a gate is only scheduled (not blocking anyone yet); red for
/// active full closures, orange otherwise.
Color closureColor(RoadClosure c, DateTime now) =>
    c.statusAt(now) == ClosureStatus.scheduled
    ? Colors.indigo.shade400
    : c.isFullClosure
    ? Colors.red.shade700
    : Colors.orange;

String ymd(DateTime d) => '${d.year}/${d.month}/${d.day}';
