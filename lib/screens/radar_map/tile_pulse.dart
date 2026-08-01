import 'package:flutter/material.dart';

/// Soft grey pulse used as the loading placeholder for base-map tiles, so that
/// a slow load reads as 'loading', not as 'blank map'.
class TilePulse extends StatefulWidget {
  const TilePulse({super.key});

  @override
  State<TilePulse> createState() => _TilePulseState();
}

class _TilePulseState extends State<TilePulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: Tween(
      begin: 0.06,
      end: 0.25,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut)),
    child: const ColoredBox(color: Colors.blueGrey),
  );
}
