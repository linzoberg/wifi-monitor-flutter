// ─────────────────────────────────────────────
// Периодический пинг 8.8.8.8 с детектом VPN.
// 1:1 порт PingThread из core/workers.py.
//
// Выход: Stream<PingResult> (broadcast) — UI и трей подписываются на одно и то же.
// Управление: start() / stop(). Прерываемый sleep реализован через
// core/interruptible_sleep.dart, поэтому stop() не ждёт окончания
// текущего интервала.
//
// Парсинг stdout вынесен в core/parsers.dart — единая точка правды
// для русско/англоязычных версий Windows.
// ─────────────────────────────────────────────

import 'dart:async';

import 'constants.dart';
import 'interruptible_sleep.dart';
import 'models.dart';
import 'parsers.dart';
import 'process_runner.dart';

class PingService {
  final int pingIntervalSec;

  final StreamController<PingResult> _controller =
      StreamController<PingResult>.broadcast();

  final InterruptibleSleep _sleep = InterruptibleSleep();

  bool _running = false;

  PingService({required int pingIntervalSec})
      : pingIntervalSec = pingIntervalSec < 1 ? 1 : pingIntervalSec;

  /// Поток результатов пинга. Можно подписываться многократно.
  Stream<PingResult> get results => _controller.stream;

  bool get isRunning => _running;

  /// Запускает фоновый цикл. Повторный вызов — игнорируется.
  void start() {
    if (_running) return;
    _running = true;
    // Не await — пусть крутится в фоне.
    unawaited(_loop());
  }

  /// Останавливает фоновый цикл и будит спящий sleep().
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _sleep.wake();
  }

  /// Закрывает stream. После dispose() сервис больше не использовать.
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  // ── Внутренний цикл ──────────────────────

  Future<void> _loop() async {
    // Стартовая задержка — как INITIAL_DELAY_MS в Python.
    if (!await _sleep.sleep(
      const Duration(milliseconds: kPingInitialDelayMs),
    )) {
      return;
    }
    if (!_running) return;

    const cmd = <String>['-n', '1', '-w', '2000', kPingHost];

    while (_running) {
      final ms = await _ping(cmd);
      if (!_running) return;

      _emit(_classify(ms));

      if (!await _sleep.sleep(Duration(seconds: pingIntervalSec))) return;
      if (!_running) return;
    }
  }

  /// Превращает «сырой» результат ping в типизированный статус.
  /// Вынесено в отдельный метод, чтобы было удобно покрыть тестами.
  PingResult _classify(int? ms) {
    if (ms == null) return const PingUnreachable();
    // 0 мс = ответ «<1мс», характерно для VPN/локального туннеля.
    if (ms <= 0) return const PingVpn();
    return PingOk(ms);
  }

  void _emit(PingResult r) {
    if (_controller.isClosed) return;
    _controller.add(r);
  }

  /// Один вызов ping. Возвращает миллисекунды или null при ошибке.
  Future<int?> _ping(List<String> args) async {
    final HiddenProcessResult result;
    try {
      result = await runHidden(
        'ping',
        args,
        timeout: const Duration(seconds: 5),
      );
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }

    if (!result.ok) return null;
    return parsePingTimeMs(result.stdout);
  }
}
