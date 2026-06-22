// Точка входа — будет переписана на шаге 7.
// Сейчас это минимальная заглушка, чтобы проект открывался в Android Studio
// и `flutter pub get` / `flutter analyze` не падали.

import 'package:flutter/material.dart';

void main() {
  runApp(const _Placeholder());
}

class _Placeholder extends StatelessWidget {
  const _Placeholder();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Wi-Fi Монитор',
      home: Scaffold(
        body: Center(
          child: Text('Каркас проекта готов. Реализация — на следующих шагах.'),
        ),
      ),
    );
  }
}
