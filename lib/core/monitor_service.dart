// ─────────────────────────────────────────────
// Основной цикл мониторинга Wi-Fi.
// 1:1 порт MonitorThread из core/workers.py:
//   • check_wifi_available → нет: «Сеть … не обнаружена»
//   • get_current_connection → да: проверяем интернет
//        ├─ есть: «Подключено к …, интернет доступен»
//        └─ нет:  «Подключено к …, но нет интернета»
//   • видим, но не подключены → промежуточный «подключаюсь…» + connect_to_wifi
//
// Выход: Stream<MonitorEvent> (broadcast) — на него подписываются и MainWindow,
// и TrayController, чтобы перекрашивать иконку.
//
// История правок:
//   • Убран regex-парсинг русского текста ошибки подключения.
//     WiFiMonitor.connectToWifi() теперь возвращает ConnectAttemptOutcome,
//     и MonitorService строит StatusConnectSuccess/Failed напрямую.
//   • Прерываемый sleep вынесен в core/interruptible_sleep.dart.
// ─────────────────────────────────────────────

import 'dart:async';

import 'interruptible_sleep.dart';
import 'models.dart';
import 'wifi_monitor.dart';

class MonitorService {
  final WiFiMonitor monitor;
  final int checkIntervalSec;

  final StreamController<MonitorEvent> _controller =
      StreamController<MonitorEvent>.broadcast();

  final InterruptibleSleep _sleep = InterruptibleSleep();

  /// Запоминаем последнее сообщение — для is_new_line (см. workers.py).
  String _lastMessage = '';

  bool _running = false;

  MonitorService({
    required this.monitor,
    required int checkIntervalSec,
  }) : checkIntervalSec = checkIntervalSec < 1 ? 1 : checkIntervalSec;

  Stream<MonitorEvent> get events => _controller.stream;

  bool get isRunning => _running;

  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop());
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _sleep.wake();
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  // ── Главный цикл ──────────────────────────

  Future<void> _loop() async {
    while (_running) {
      MonitorStatus? status;
      try {
        status = await _tick();
      } catch (e) {
        // Не даём упасть всему циклу — как в Python (BLE001).
        _emit(StatusError(e.toString()), statusChanged: true);
        if (!await _sleep.sleep(const Duration(seconds: 5))) return;
        if (!_running) return;
        continue;
      }

      if (status != null) {
        // Внутри _tick могла быть промежуточная эмиссия (StatusConnecting),
        // тогда status == null и мы её не дублируем.
        final text = status.message(monitor.ssid);
        final changed = text != _lastMessage;
        _emit(status, statusChanged: changed);
        _lastMessage = text;
      }

      if (!await _sleep.sleep(Duration(seconds: checkIntervalSec))) return;
      if (!_running) return;
    }
  }

  /// Один проход проверки. Возвращает финальный статус либо null,
  /// если уже всё разэмитировали внутри (как делает _tick в Python).
  Future<MonitorStatus?> _tick() async {
    if (!await monitor.checkWifiAvailable()) {
      return const StatusNetworkMissing();
    }

    if (await monitor.getCurrentConnection()) {
      final online = await monitor.checkInternet();
      return online
          ? const StatusConnectedOnline()
          : const StatusConnectedOffline();
    }

    // Сеть видна, но мы не подключены — пробуем подключиться.
    // Эмитим «подключаюсь...», затем итог. Финальное сообщение пишем
    // и в _lastMessage, чтобы основной цикл не считал его «новым».
    _emit(const StatusConnecting(), statusChanged: true);
    _lastMessage = const StatusConnecting().message(monitor.ssid);

    final outcome = await monitor.connectToWifi();
    final result = outcome.success
        ? const StatusConnectSuccess()
        : StatusConnectFailed(
            attempts: outcome.attempts,
            lastError: outcome.lastError,
          );

    _emit(result, statusChanged: true);
    _lastMessage = result.message(monitor.ssid);
    return null;
  }

  // ── Эмиссия ──────────────────────────────

  void _emit(MonitorStatus s, {required bool statusChanged}) {
    if (_controller.isClosed) return;
    _controller.add(
      MonitorEvent(status: s, statusChanged: statusChanged),
    );
  }
}
