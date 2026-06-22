// ─────────────────────────────────────────────
// Кольцевой буфер строк лога для UI.
//
// Раньше эта логика жила прямо в _MainWindowState (append/replace/dedup/trim),
// и её было трудно покрыть тестами. Теперь:
//   • LogBuffer держит список форматированных строк ("[HH:MM:SS] msg"),
//   • знает про дедупликацию (повтор того же raw-message → обновляем последнюю),
//   • знает про newLine vs replace-last (1:1 с add_status() из Python),
//   • знает про лимит kMaxLogLines.
//
// MainWindow остаётся отвечать только за прокрутку и setState.
// ─────────────────────────────────────────────

import 'constants.dart';

/// Источник времени — параметризован, чтобы тесты могли подсунуть
/// фиксированное "сейчас" без monkey-patch-ев.
typedef NowProvider = DateTime Function();

class LogBuffer {
  final int maxLines;
  final NowProvider _now;

  final List<String> _lines = <String>[];
  String _lastRawMessage = '';

  LogBuffer({
    this.maxLines = kMaxLogLines,
    NowProvider? now,
  }) : _now = now ?? DateTime.now;

  /// Текущие строки лога (read-only view, чтобы UI не мог их случайно
  /// изменить мимо API).
  List<String> get lines => List<String>.unmodifiable(_lines);

  int get length => _lines.length;
  bool get isEmpty => _lines.isEmpty;

  /// Добавляет/обновляет последнюю строку. Поведение 1:1 с Python add_status:
  ///   • повтор того же raw-message → апдейт времени в последней строке;
  ///   • newLine=true → всегда новая строка;
  ///   • newLine=false → заменяет последнюю.
  ///
  /// Возвращает true, если набор строк визуально изменился (всегда true
  /// в текущей реализации — оставлено как контракт на будущее, если
  /// захочется глушить «no-op» апдейты).
  bool add(String message, {bool newLine = false}) {
    final formatted = '[${_formatTime(_now())}] $message';

    if (message == _lastRawMessage && _lines.isNotEmpty) {
      _lines[_lines.length - 1] = formatted;
    } else if (newLine || _lines.isEmpty) {
      _lines.add(formatted);
      _lastRawMessage = message;
      _trim();
    } else {
      _lines[_lines.length - 1] = formatted;
      _lastRawMessage = message;
    }
    return true;
  }

  /// Полный сброс буфера. Используется кнопкой «Очистить лог».
  void clear() {
    _lines.clear();
    _lastRawMessage = '';
  }

  void _trim() {
    if (_lines.length <= maxLines) return;
    _lines.removeRange(0, _lines.length - maxLines);
  }

  static String _formatTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}
