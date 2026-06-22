// ─────────────────────────────────────────────
// Стили UI и константы окна.
//
// Аналог ui/styles.py — те же цвета, шрифты и размеры, но в терминах
// Flutter (Color/TextStyle/ButtonStyle), чтобы дизайн остался 1:1.
//
// Палитра (HEX → название):
//   #2c3e50 — тёмно-серо-синий, заголовок
//   #7f8c8d — серый, второстепенный текст / "нейтральная" статусная строка
//   #ecf0f1 — почти белый, фон ping-плашки и текстового лога
//   #bdc3c7 — серая рамка ping-плашки / лога / разделителя
//   #2ecc71 / #27ae60 — зелёный "запуск" / hover (онлайн)
//   #e74c3c / #c0392b — красный "стоп" / hover (нет сети)
//   #3498db / #2980b9 — синий "очистить лог"
//   #95a5a6 / #7f8c8d — серый "настройки"
//   #f39c12          — оранжевый (VPN / средний пинг)
// ─────────────────────────────────────────────

import 'package:flutter/material.dart';

// ── Окно ────────────────────────────────────
const String kAppTitle = 'Wi-Fi Монитор';
const double kAppWidth = 600;
const double kAppHeight = 400;

// ── Палитра ─────────────────────────────────
class AppColors {
  AppColors._();

  // Текст
  static const Color titleDark = Color(0xFF2C3E50);
  static const Color textMuted = Color(0xFF7F8C8D);
  static const Color borderLight = Color(0xFFBDC3C7);
  static const Color surfaceLight = Color(0xFFECF0F1);

  // Кнопки
  static const Color greenBg = Color(0xFF2ECC71);
  static const Color greenBgHover = Color(0xFF27AE60);

  static const Color redBg = Color(0xFFE74C3C);
  static const Color redBgHover = Color(0xFFC0392B);

  static const Color blueBg = Color(0xFF3498DB);
  static const Color blueBgHover = Color(0xFF2980B9);

  static const Color grayBg = Color(0xFF95A5A6);
  static const Color grayBgHover = Color(0xFF7F8C8D);

  // Статусы
  static const Color statusOk = Color(0xFF27AE60);
  static const Color statusError = Color(0xFFE74C3C);
  static const Color statusWarn = Color(0xFFF39C12);
}

// ── Шрифты ──────────────────────────────────
const String kFontUi = 'Arial';
const String kFontMono = 'Consolas';

// Размеры: в Qt 9pt рендерится как ~12px при 96 DPI (1pt ≈ 1.33px).
// Flutter же работает в логических пикселях, поэтому чистый 9 выглядит
// вдвое мельче. Используем эквиваленты в пикселях, чтобы визуально совпадать
// с Python-оригиналом.
const TextStyle kTitleStyle = TextStyle(
  fontFamily: kFontUi,
  fontSize: 18,
  fontWeight: FontWeight.bold,
  color: AppColors.titleDark,
);

const TextStyle kInfoStyle = TextStyle(
  fontFamily: kFontUi,
  fontSize: 13,
  color: AppColors.textMuted,
);

const TextStyle kPingTitleStyle = TextStyle(
  fontFamily: kFontUi,
  fontSize: 12,
  color: AppColors.textMuted,
);

const TextStyle kPingValueBaseStyle = TextStyle(
  fontFamily: kFontUi,
  fontSize: 12,
  fontWeight: FontWeight.bold,
);

const TextStyle kLogStyle = TextStyle(
  fontFamily: kFontMono,
  fontSize: 12,
  color: AppColors.titleDark,
  height: 1.3,
);

const TextStyle kBottomStatusBaseStyle = TextStyle(
  fontFamily: kFontUi,
  fontSize: 12,
);

const TextStyle kHintStyle = TextStyle(
  color: AppColors.textMuted,
  fontSize: 12,
);

// ── Декорации ───────────────────────────────

/// Контейнер ping-плашки (фон + рамка + скругление) —
/// аналог STYLE_PING_FRAME из Python.
BoxDecoration kPingFrameDecoration() => BoxDecoration(
      color: AppColors.surfaceLight,
      border: Border.all(color: AppColors.borderLight),
      borderRadius: BorderRadius.circular(5),
    );

/// Контейнер для лога (тот же фон/рамка/скругление, но без padding —
/// padding задаётся внутренним SingleChildScrollView/TextField).
BoxDecoration kLogDecoration() => BoxDecoration(
      color: AppColors.surfaceLight,
      border: Border.all(color: AppColors.borderLight),
      borderRadius: BorderRadius.circular(5),
    );

/// Горизонтальный разделитель (1px полоска цвета #bdc3c7).
Widget kSeparator() => Container(
      height: 1,
      color: AppColors.borderLight,
    );

// ── Кнопки ──────────────────────────────────

/// Стиль кнопки 1:1 с button_style() из Python:
///   bold-белый текст, padding 8x16, border-radius 4, цвет + hover.
ButtonStyle appButtonStyle({
  required Color background,
  required Color backgroundHover,
}) {
  return ButtonStyle(
    foregroundColor: WidgetStateProperty.all(Colors.white),
    elevation: WidgetStateProperty.all(0),
    // Поднял vertical с 8 до 12 + зафиксировал minimumSize, чтобы bold-текст
    // не обрезался снизу. Горизонтальный padding уменьшил с 16 до 12, чтобы
    // 4 кнопки влезали в 600px-окно без обрезки.
    padding: WidgetStateProperty.all(
      const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    ),
    minimumSize: WidgetStateProperty.all(const Size(0, 40)),
    shape: WidgetStateProperty.all(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    textStyle: WidgetStateProperty.all(
      const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
    ),
    backgroundColor: WidgetStateProperty.resolveWith<Color>((states) {
      if (states.contains(WidgetState.disabled)) {
        // Полупрозрачный, чтобы было видно "отключённое" состояние.
        return background.withValues(alpha: 0.5);
      }
      if (states.contains(WidgetState.hovered) ||
          states.contains(WidgetState.pressed) ||
          states.contains(WidgetState.focused)) {
        return backgroundHover;
      }
      return background;
    }),
  );
}

ButtonStyle get kButtonStart =>
    appButtonStyle(background: AppColors.greenBg, backgroundHover: AppColors.greenBgHover);

ButtonStyle get kButtonStop =>
    appButtonStyle(background: AppColors.redBg, backgroundHover: AppColors.redBgHover);

ButtonStyle get kButtonClear =>
    appButtonStyle(background: AppColors.blueBg, backgroundHover: AppColors.blueBgHover);

ButtonStyle get kButtonSettings =>
    appButtonStyle(background: AppColors.grayBg, backgroundHover: AppColors.grayBgHover);

// ── Строка формы (Qt-подобный QFormLayout) ──────

/// Общая вёрстка строки в диалогах настроек / учётных данных.
/// Раньше жила в двух файлах почти буква-в-букву.
class AppFormRow extends StatelessWidget {
  final String label;
  final Widget field;

  /// Ширина левой колонки с подписью. Совпадает с ранее использовавшимися
  /// 110 (credentials) / 170 (prefs) — по умолчанию 110.
  final double labelWidth;

  const AppFormRow({
    super.key,
    required this.label,
    required this.field,
    this.labelWidth = 110,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: labelWidth,
            child: Text(
              label,
              style: const TextStyle(color: AppColors.titleDark),
            ),
          ),
          Expanded(child: field),
        ],
      ),
    );
  }
}

// ── Тема ────────────────────────────────────

/// Светлая Fusion-подобная тема, чтобы соответствовать
/// `app.setStyle("Fusion")` из Python и не "уплывать" в Material 3 палитру.
ThemeData buildAppTheme() {
  return ThemeData(
    useMaterial3: false,
    fontFamily: kFontUi,
    scaffoldBackgroundColor: Colors.white,
    dialogTheme: const DialogThemeData(backgroundColor: Colors.white),
    colorScheme: const ColorScheme.light(
      primary: AppColors.titleDark,
      secondary: AppColors.blueBg,
      surface: Colors.white,
    ),
    textTheme: const TextTheme(
      bodyMedium: TextStyle(fontFamily: kFontUi, color: AppColors.titleDark),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      isDense: true,
      border: OutlineInputBorder(),
    ),
  );
}
