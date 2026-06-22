// ─────────────────────────────────────────────
// Сервис пинга 8.8.8.8.
//
// Аналог core/workers.py → PingThread.
// Вместо QThread + pyqtSignal используем Stream<PingResult> +
// внутренний цикл с прерываемой задержкой (флаг + Future.delayed).
//
// Жизненный цикл:
//   final svc = PingService(pingIntervalSec: 5);
//   svc.results.listen((r) { ... });
//   svc.start();
//   ...
//   await svc.stop();
//   svc.dispose();
//
// Интервал можно поменять через restartWith(newInterval) — поведение
// идентично Python (там перезапускали поток с новым параметром).
// ─────────────────────────────────────────────

import 'dart:async';

import 'constants.dart';
import 'models.dart';
import 'process_runner.dart';

/// Прекомпилированные regex для разбора вывода ping.
/// Поддерживают и русский ("Время = 42мс"), и английский ("time=42ms").
final RegExp _kRegPingTime = RegExp(
  r'(?:[Вв]ремя|[Tt]ime)\s*[=<]\s*(\d+)',
);
final RegExp _kRegPingLt1 = RegExp(
  r'(?:[Вв]ремя|[Tt]ime)\s*<\s*1',
);

class PingService {
  /// Интервал между пингами в секундах.
  int _pingIntervalSec;

  final _controller = StreamController<PingResult>.broadcast();
  bool _running = false;
  Completer<void>? _runCompleter;

  PingService({int pingIntervalSec = kDefaultPingInterval})
      : _pingIntervalSec = pingIntervalSec < 1 ? 1 : pingIntervalSec;

  /// Stream результатов пинга. Можно подписываться неограниченно — broadcast.
  Stream<PingResult> get results => _controller.stream;

  /// Запустить цикл пинга. Если уже запущен — no-op.
  void start() {
    if (_running) return;
    _running = true;
    _runCompleter = Completer<void>();
    unawaited(_loop());
  }

  /// Остановить цикл и дождаться, пока текущая итерация завершится.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    final completer = _runCompleter;
    _runCompleter = null;
    if (completer != null) {
      await completer.future;
    }
  }

  /// Закрыть Stream. После dispose() сервис уже не использовать.
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  /// Удобный шорткат: остановить, поменять интервал, снова запустить.
  Future<void> restartWith(int pingIntervalSec) async {
    await stop();
    _pingIntervalSec = pingIntervalSec < 1 ? 1 : pingIntervalSec;
    start();
  }

  // ── Внутреннее ───────────────────────────────

  Future<void> _loop() async {
    try {
      // Начальная задержка (как INITIAL_DELAY_MS в Python).
      if (!await _sleepInterruptible(
        const Duration(milliseconds: kPingInitialDelayMs),
      )) {
        return;
      }

      while (_running) {
        final result = await _pingOnce();
        if (!_running) return;
        _controller.add(result);

        if (!await _sleepInterruptible(Duration(seconds: _pingIntervalSec))) {
          return;
        }
      }
    } finally {
      _runCompleter?.complete();
    }
  }

  /// Один пинг → PingResult.
  Future<PingResult> _pingOnce() async {
    HiddenProcessResult result;
    try {
      result = await runHidden(
        'ping',
        ['-n', '1', '-w', '2000', kPingHost],
        timeout: const Duration(seconds: 5),
      );
    } on TimeoutException {
      return const PingUnreachable();
    } catch (_) {
      return const PingUnreachable();
    }

    final output = result.stdout;
    final match = _kRegPingTime.firstMatch(output);
    if (match != null) {
      final ms = int.parse(match.group(1)!);
      // Время < 1 мс по основному regex (формат "Время=0мс") тоже считаем VPN.
      if (ms <= 1) return const PingVpn();
      return PingOk(ms);
    }

    // Формат "Время < 1мс" — успешный, но без числа. Это признак VPN.
    if (result.ok && _kRegPingLt1.hasMatch(output)) {
      return const PingVpn();
    }
    return const PingUnreachable();
  }

  /// Спит [duration], но просыпается, если выставлен флаг остановки.
  /// Возвращает false, если был остановлен.
  Future<bool> _sleepInterruptible(Duration duration) async {
    final deadline = DateTime.now().add(duration);
    const tick = Duration(milliseconds: 100);
    while (_running && DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      final step = remaining < tick ? remaining : tick;
      if (step.inMicroseconds <= 0) break;
      await Future<void>.delayed(step);
    }
    return _running;
  }
}
