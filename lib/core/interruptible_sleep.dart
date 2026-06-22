// ─────────────────────────────────────────────
// InterruptibleSleep — прерываемая пауза для фоновых циклов.
//
// Раньше идентичный код жил и в MonitorService, и в PingService:
// Completer + Timer + проверка identical(...) в finally. Вынес в один
// маленький класс, чтобы не дублировать и не разъезжаться.
//
// Семантика:
//   • sleep(d) → true  — проснулись штатно по таймеру
//                false — разбудили досрочно через wake()
//   • wake() — будит текущий sleep, если он есть. Идемпотентен.
//   • Поддерживается повторный sleep() после wake().
// ─────────────────────────────────────────────

import 'dart:async';

class InterruptibleSleep {
  Completer<void>? _completer;

  /// Засыпает на [duration].
  /// Возвращает true, если проснулся по таймеру; false — если разбудили.
  Future<bool> sleep(Duration duration) async {
    final completer = Completer<void>();
    _completer = completer;

    var firedByTimer = false;
    final timer = Timer(duration, () {
      firedByTimer = true;
      if (!completer.isCompleted) completer.complete();
    });

    try {
      await completer.future;
    } finally {
      timer.cancel();
      if (identical(_completer, completer)) {
        _completer = null;
      }
    }
    return firedByTimer;
  }

  /// Будит текущий sleep, если он идёт. Безопасно вызывать всегда.
  void wake() {
    final c = _completer;
    if (c != null && !c.isCompleted) c.complete();
  }
}
