import 'package:flutter/material.dart';

import 'screens/stown_screen.dart';
import 'theme.dart';

/// Точка входа отдельного приложения «STOWN Метка».
///
/// Содержит только экран формирования и вещания STOWN-метки (вкладка «Метка»
/// из полного приложения) — без вкладок, сканера, шлюза и входа. Собирается
/// флейвором `tag`:
///   flutter build apk --release --flavor tag -t lib/main_tag.dart
void main() {
  runApp(const StownTagApp());
}

class StownTagApp extends StatelessWidget {
  const StownTagApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE-Метка',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const StownScreen(standalone: true),
    );
  }
}
