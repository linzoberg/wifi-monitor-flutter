// ─────────────────────────────────────────────
// Единая точка правды «семантика статуса → цвет».
//
// До рефакторинга маппинг был дважды:
//   • _statusBottomStyle() в MainWindow (нижняя полоса);
//   • _severityColor()     в MainWindow (ping-плашка).
//
// Теперь оба места ходят сюда. Если захочется поменять цвет «warn» —
// меняется ровно в одном файле.
// ─────────────────────────────────────────────

import 'package:flutter/material.dart';

import '../ui/styles.dart';
import 'models.dart';

/// Цвет, соответствующий семантическому уровню статуса.
Color severityColor(StatusSeverity s) {
  switch (s) {
    case StatusSeverity.ok:
      return AppColors.statusOk;
    case StatusSeverity.warn:
      return AppColors.statusWarn;
    case StatusSeverity.error:
      return AppColors.statusError;
    case StatusSeverity.neutral:
      return AppColors.textMuted;
  }
}

/// Жирность шрифта для нижней статусной полосы.
/// Нейтральный статус — обычный, всё остальное — bold (как было в UI).
FontWeight severityWeight(StatusSeverity s) {
  return s == StatusSeverity.neutral ? FontWeight.normal : FontWeight.bold;
}
