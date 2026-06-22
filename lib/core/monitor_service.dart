// ─────────────────────────────────────────────
// Основной цикл мониторинга Wi-Fi.
//
// Аналог core/workers.py → MonitorThread.
// Вместо QThread + 2 pyqtSignal используем Stream<MonitorEvent>.
// Один Event содержит и статус, и флаг "новая строка лога / обновить
// последнюю" — 1:1 с парой (message, is_new_line) из Python.
//
// Алгоритм одного «такта» полностью повторяет Python:
//   1. Если нет подключения к нужной сети — проверить, видна ли SSID
//      в эфире. Если не видна — StatusNetworkMissing.
//   2. Если видна и не подключены — StatusConnecting → запустить
//      connectToWifi() → StatusConnectSuccess | StatusConnectFailed.
//   3. Если подключены — проверить интернет → StatusConnectedOnline
//      или StatusConnectedOffline.
//
// Жизненный цикл:
//   final svc = MonitorService(monitor: ..., checkIntervalSec: 5);
//   svc.events.listen(...);
//   svc.start();
//   await svc.stop();
//   await svc.dispose();
// ─────────────────────────────────────────────

import 'dart:async';

import 'constants.dart';
import 'models.dart';
import 'wifi_monitor.dart';

class MonitorService {
  final WiFiMonitor monitor;
  int _checkIntervalSec;

  final _controller = StreamController<MonitorEvent>.broadcast();
  bool _running = false;
  Completer<void>? _runCompleter;

  /// Последний отправленный статус — нужен для определения statusChanged:
  /// если "тип" статуса не изменился, повторяющиеся такты обновляют
  /// последнюю строку лога (как is_new_line=False в Python).
  MonitorStatus? _lastStatus;

  MonitorService({
    required this.monitor,
    int checkIntervalSec = kDefaultCheckInterval,
  }) : _checkIntervalSec = checkIntervalSec < 1 ? 1 : checkIntervalSec;

  /// Stream событий мониторинга.
  Stream<MonitorEvent> get events => _controller.stream;

  /// Запущен ли сейчас цикл.
  bool get isRunning => _running;

  /// Запустить цикл. Если уже запущен — no-op.
  void start() {
    if (_running) return;
    _running = true;
    _lastStatus = null;
    _runCompleter = Completer<void>();
    unawaited(_loop());
  }

  /// Остановить и дождаться, пока текущая итерация доработает.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    final completer = _runCompleter;
    _runCompleter = null;
    if (completer != null) {
      await completer.future;
    }
  }

  /// Закрыть Stream. Использовать только при завершении приложения.
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  /// Удобный шорткат: остановить, поменять интервал, снова запустить.
  Future<void> restartWith(int checkIntervalSec) async {
    await stop();
    _checkIntervalSec = checkIntervalSec < 1 ? 1 : checkIntervalSec;
    start();
  }

  // ── Внутреннее ───────────────────────────────

  Future<void> _loop() async {
    try {
      while (_running) {
        try {
          await _tick();
        } catch (e) {
          _emit(StatusError(e.toString()));
        }
        if (!_running) return;

        if (!await _sleepInterruptible(Duration(seconds: _checkIntervalSec))) {
          return;
        }
      }
    } finally {
      _runCompleter?.complete();
    }
  }

  /// Один такт проверки — повторяет логику MonitorThread._tick() из Python.
  ///
  /// Порядок 1:1 с Python core/workers.py:
  ///   1. Каждый тик проверяем доступность сети в эфире (без условий).
  ///   2. Если сеть не видна — `StatusNetworkMissing`, `monitor.connected=false`.
  ///   3. Если видна и мы подключены — пингуем интернет.
  ///   4. Если видна, но не подключены — пробуем connectToWifi().
  Future<void> _tick() async {
    if (!_running) return;

    // 1. Видна ли наша сеть?
    final available = await monitor.checkWifiAvailable();
    if (!_running) return;

    if (!available) {
      // В Python тут же сбрасывали connected через connection_changed(false).
      monitor.connected = false;
      _emit(const StatusNetworkMissing());
      return;
    }

    // 2. Подключены ли к нужной сети?
    final connected = await monitor.getCurrentConnection();
    if (!_running) return;

    if (connected) {
      // Подключены — проверим интернет.
      final online = await monitor.checkInternet();
      if (!_running) return;

      if (online) {
        _emit(const StatusConnectedOnline());
      } else {
        _emit(const StatusConnectedOffline());
      }
      return;
    }

    // 3. Сеть видна, но не подключены — пробуем подключиться.
    //    Этот шаг может занять до kReconnectAttempts * kReconnectDelay секунд,
    //    поэтому показываем промежуточный статус с changed=true.
    _emit(const StatusConnecting());

    final result = await monitor.connectToWifi();
    if (!_running) return;

    // monitor.connected уже выставлен внутри connectToWifi/getCurrentConnection.
    if (result.ok) {
      _emit(const StatusConnectSuccess());
    } else {
      _emit(
        StatusConnectFailed(
          attempts: kReconnectAttempts,
          lastError: result.message,
        ),
      );
    }
  }

  /// Отправляет событие в Stream и решает, новая ли это строка лога.
  ///
  /// Правило (1:1 с Python `is_new_line=status_changed`):
  ///   если тип последнего статуса отличается от текущего — это новая строка;
  ///   повторы того же типа просто обновляют последнюю строку.
  ///
  /// Дедупликацию совсем одинаковых сообщений (с обновлением timestamp)
  /// делает UI в add_status — здесь не дублируем.
  void _emit(MonitorStatus status) {
    final changed = _lastStatus == null ||
        _lastStatus.runtimeType != status.runtimeType;
    _lastStatus = status;
    _controller.add(MonitorEvent(status: status, statusChanged: changed));
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
