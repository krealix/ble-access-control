import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'lock_send_page.dart';

void main() {
  runApp(const Hm10App());
}

class Hm10App extends StatelessWidget {
  const Hm10App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HM10 Замки',
      debugShowCheckedModeBanner: false,
      theme: buildDarkTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeMode.dark,
      home: const LockSendPage(),
    );
  }
}
