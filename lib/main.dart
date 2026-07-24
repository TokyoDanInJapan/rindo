import 'package:flutter/material.dart';

import 'screens/radar_map_screen.dart';

void main() => runApp(const RindoApp());

/// Root widget: Material theme + the single map screen.
class RindoApp extends StatelessWidget {
  const RindoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rindo',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: const RadarMapScreen(),
    );
  }
}
