// ─────────────────────────────────────────────
// ViewModel главного окна.
//
// До рефакторинга _MainWindowState весил ~400 строк и совмещал:
//   • владение MonitorService / PingService,
//   • lifecycle (start/stop/dispose),
//   • буфер лога,
//   • маппинг severity → цвет,
//   • рендер виджетов.
//
// Теперь:
//   • MainWindowController (ChangeNotifier) знает «что показывать».
//   • MainWindow (StatefulWidget) знает «как нарисовать» и про окно/трей.
//
// Преимущества:
//   • Логика тестируется без виджет-теста (мок-сервисы инжектятся в конструктор).
//   • setState() заменён на notifyListeners() — один источник правды для UI.
//   • Перестроение сервисов на смену настроек локализовано в одной точке
//     (applyPrefs), без дублирования стартов/стопов.
// ─────────────────────────────────────────────

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/log_buffer.dart';
import '../core/models.dart';
import '../core/monitor_service.dart';
import '../core/ping_service.dart';
import '../core/settings_service.dart';
import '../core/wifi_monitor.dart';

/// Фабрики сервисов — параметризованы, чтобы тесты подсовывали моки.
typedef MonitorFactory = MonitorService Function(
  WiFiMonitor wifi,
  int checkIntervalSec,
);
typedef PingFactory = PingService Function(int pingIntervalSec);
typedef WiFiFactory = WiFiMonitor Function(
  Credentials credentials,
  Prefs prefs,
);

class MainWindowController extends ChangeNotifier {
  // ── Зависимости ──────────────────────────
  final Credentials credentials;
  final SettingsService settings;

  final MonitorFactory _monitorFactory;
  final PingFactory _pingFactory;
  final WiFiFactory _wifiFactory;

  // ── Состояние домена ─────────────────────
  Prefs _prefs;
  WiFiMonitor _wifi;
  MonitorService? _monitor;
  PingService? _ping;
  StreamSubscription<MonitorEvent>? _monitorSub;
  StreamSubscription<PingResult>? _pingSub;

  // ── Состояние UI ─────────────────────────
  final LogBuffer log = LogBuffer();

  PingResult _ping_ = const PingIdle();
  MonitorStatus _status = const StatusIdle();

  bool _isRunning = false;
  bool _disposed = false;

  /// Колбэк для трея — вызывается на каждое изменение connected.
  /// Контроллер про сам трей знать не должен (отделение слоёв).
  void Function(bool connected, String ssid)? onConnectionChanged;

  MainWindowController({
    required this.credentials,
    required Prefs initialPrefs,
    required this.settings,
    MonitorFactory? monitorFactory,
    PingFactory? pingFactory,
    WiFiFactory? wifiFactory,
  })  : _prefs = initialPrefs,
        _monitorFactory = monitorFactory ?? _defaultMonitorFactory,
        _pingFactory = pingFactory ?? _defaultPingFactory,
        _wifiFactory = wifiFactory ?? _defaultWifiFactory,
        _wifi = (wifiFactory ?? _defaultWifiFactory)(credentials, initialPrefs);

  // ── Геттеры для UI ───────────────────────
  Prefs get prefs => _prefs;
  String get ssid => _wifi.ssid;
  bool get isRunning => _isRunning;
  PingResult get pingResult => _ping_;
  MonitorStatus get status => _status;

  // ─────────────────────────────────────────
  // Lifecycle
  // ─────────────────────────────────────────

  /// Запускает оба сервиса (мониторинг + пинг) и пишет в лог стартовое сообщение.
  /// Безопасно для повторного вызова.
  void start() {
    _startPingIfNeeded();
    _startMonitorIfNeeded();
  }

  void _startMonitorIfNeeded() {
    if (_isRunning) return;
    final svc = _monitorFactory(_wifi, _prefs.checkInterval);
    _monitorSub = svc.events.listen(_onMonitorEvent);
    svc.start();
    _monitor = svc;
    _isRunning = true;
    log.add('Мониторинг запущен', newLine: true);
    _safeNotify();
  }

  void _startPingIfNeeded() {
    if (_ping != null) return;
    final svc = _pingFactory(_prefs.pingInterval);
    _pingSub = svc.results.listen(_onPingResult);
    svc.start();
    _ping = svc;
  }

  /// Останавливает мониторинг. Пинг продолжает работать (как в Python).
  Future<void> stopMonitoring({bool writeLog = true}) async {
    final svc = _monitor;
    if (svc == null) {
      _isRunning = false;
      return;
    }
    await _monitorSub?.cancel();
    _monitorSub = null;
    _monitor = null;
    await svc.dispose();
    _isRunning = false;
    if (writeLog) log.add('Мониторинг остановлен', newLine: true);
    _safeNotify();
  }

  /// Кнопка «Запуск мониторинга».
  void startMonitoring() => _startMonitorIfNeeded();

  Future<void> _stopPing() async {
    final svc = _ping;
    if (svc == null) return;
    await _pingSub?.cancel();
    _pingSub = null;
    _ping = null;
    await svc.dispose();
  }

  void clearLog() {
    log.clear();
    log.add('Лог очищен', newLine: true);
    _safeNotify();
  }

  /// Применяет новые настройки и при необходимости пересоздаёт сервисы.
  /// Решает, что именно перезапустить — единая точка, без дублирования логики.
  Future<void> applyPrefs(Prefs updated) async {
    final old = _prefs;
    _prefs = updated;
    await settings.savePrefs(updated);

    final monitorNeedsRebuild = updated.checkInterval != old.checkInterval ||
        updated.routerIp != old.routerIp;
    if (monitorNeedsRebuild) {
      final wasRunning = _isRunning;
      await stopMonitoring(writeLog: false);
      _wifi = _wifiFactory(credentials, _prefs);
      if (wasRunning) _startMonitorIfNeeded();
    }

    if (updated.pingInterval != old.pingInterval) {
      await _stopPing();
      _startPingIfNeeded();
    }

    log.add(
      'Настройки обновлены: проверка ${updated.checkInterval} с, '
      'пинг ${updated.pingInterval} с',
      newLine: true,
    );
    _safeNotify();
  }

  // ─────────────────────────────────────────
  // Внутренние обработчики
  // ─────────────────────────────────────────

  void _onMonitorEvent(MonitorEvent event) {
    _status = event.status;
    log.add(event.status.message(ssid), newLine: event.statusChanged);
    onConnectionChanged?.call(event.status.isConnected, ssid);
    _safeNotify();
  }

  void _onPingResult(PingResult r) {
    _ping_ = r;
    _safeNotify();
  }

  // ─────────────────────────────────────────
  // Dispose
  // ─────────────────────────────────────────

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    await _monitorSub?.cancel();
    await _pingSub?.cancel();
    await _monitor?.dispose();
    await _ping?.dispose();

    super.dispose();
  }

  void _safeNotify() {
    if (_disposed) return;
    notifyListeners();
  }
}

// ── Дефолтные фабрики ──────────────────────

MonitorService _defaultMonitorFactory(WiFiMonitor wifi, int checkIntervalSec) =>
    MonitorService(monitor: wifi, checkIntervalSec: checkIntervalSec);

PingService _defaultPingFactory(int pingIntervalSec) =>
    PingService(pingIntervalSec: pingIntervalSec);

WiFiMonitor _defaultWifiFactory(Credentials c, Prefs p) => WiFiMonitor(
      ssid: c.ssid,
      password: c.password,
      routerIp: p.routerIp,
    );
