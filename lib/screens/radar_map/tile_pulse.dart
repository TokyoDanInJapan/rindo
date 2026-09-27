import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// Soft grey pulse used as the loading placeholder for base-map tiles, so that
/// a slow load reads as 'loading', not as 'blank map'.
///
/// Every loading tile shares one pulse, see [_SharedPulse].
class TilePulse extends StatefulWidget {
  const TilePulse({super.key});

  @override
  State<TilePulse> createState() => _TilePulseState();
}

class _TilePulseState extends State<TilePulse> {
  static final _opacity = Tween<double>(
    begin: 0.06,
    end: 0.25,
  ).animate(_SharedPulse.instance);

  @override
  void initState() {
    super.initState();
    _SharedPulse.instance.attach();
  }

  @override
  void dispose() {
    _SharedPulse.instance.detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: _opacity,
    child: const ColoredBox(color: Colors.blueGrey),
  );
}

/// One pulse for every loading tile. A zoom-out can have dozens of tiles in
/// flight, and each used to run its own AnimationController: dozens of
/// tickers for one visual beat, drifting out of phase with each other. This
/// one ticks only while at least one tile is attached, so a fully loaded map
/// schedules no frames for it.
class _SharedPulse extends Animation<double>
    with
        AnimationEagerListenerMixin,
        AnimationLocalListenersMixin,
        AnimationLocalStatusListenersMixin {
  _SharedPulse._();

  static final instance = _SharedPulse._();

  /// One way, dark to light. The pulse runs there and back, like
  /// `repeat(reverse: true)`.
  static const _half = Duration(milliseconds: 900);

  Ticker? _ticker;
  int _users = 0;
  double _value = 0;

  @override
  double get value => _value;

  @override
  AnimationStatus get status => AnimationStatus.forward;

  void attach() {
    if (_users++ == 0) {
      _ticker = Ticker(_onTick, debugLabel: 'TilePulse')..start();
    }
  }

  void detach() {
    if (--_users == 0) {
      _ticker?.dispose();
      _ticker = null;
    }
  }

  void _onTick(Duration elapsed) {
    final half = _half.inMicroseconds;
    final t = elapsed.inMicroseconds % (2 * half) / half; // 0..2
    _value = Curves.easeInOut.transform(t <= 1 ? t : 2 - t);
    notifyListeners();
  }
}
