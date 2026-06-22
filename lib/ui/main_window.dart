// ─────────────────────────────────────────────
// Главное окно приложения.
//
// 1:1 порт ui/window.py → MainWindow:
//   • Заголовок "Wi-Fi Монитор", фикс. размер 600×400 (через window_manager).
//   • Подпись "Мониторинг сети: <SSID>".
//   • Ping-плашка (Ping: <значение> с цветом).
//   • 1px разделитель.
//   • Лог: моноширинный, ≤ kMaxLogLines строк, дедупликация повторов.
//   • Кнопки: «Запуск мониторинга» / «Остановить» / «Очистить лог» / «Настройки».
//   • Нижняя статусная строка с цветом (зелёный/красный/серый).
//   • Закрытие окна → preventClose → hide() + балун в трее.
//   • На смену настроек: при изменении checkInterval / routerIp пересоздаём
//     WiFiMonitor + MonitorService; при смене pingInterval — пересоздаём
//     PingService.
//
// Что было оптимизировано (без потери функционала и без изменения дизайна):
//   • Цвет нижнего статуса теперь берётся из MonitorStatus.severity, а не
//     из подстрок в русском тексте — нельзя «потерять» сообщение из-за опечатки.
//   • Цвет ping-плашки берётся из PingResult.severity — одна точка правды.
//   • Свёрнутый список кнопок построен в цикле, чтобы не дублировать стили.
//   • Лог-список переиспользует общий ScrollController и автоскролл идёт
//     только тогда, когда пользователь уже у нижней границы (не «угоняет»
//     прокрутку, если человек читает старые строки).
// ─────────────────────────────────────────────

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/constants.dart';
import '../core/models.dart';
import '../core/monitor_service.dart';
import '../core/ping_service.dart';
import '../core/settings_service.dart';
import '../core/wifi_monitor.dart';
import 'prefs_dialog.dart';
import 'styles.dart';
import 'tray_controller.dart';

class MainWindow extends StatefulWidget {
  /// Учётные данные, введённые на старте (или подгруженные из storage).
  final Credentials credentials;

  /// Уже загруженные пользовательские настройки.
  final Prefs initialPrefs;

  /// Сервисы, не относящиеся к Wi-Fi (нужны для диалогов и сохранения).
  final SettingsService settings;

  /// Контроллер трея — окно меняет ему иконку и принимает события
  /// "Открыть" / "Выход".
  final TrayController tray;

  /// Колбэк выхода — вызывается из меню трея и кнопки закрытия трея.
  final Future<void> Function() onQuit;

  const MainWindow({
    super.key,
    required this.credentials,
    required this.initialPrefs,
    required this.settings,
    required this.tray,
    required this.onQuit,
  });

  @override
  State<MainWindow> createState() => _MainWindowState();
}

class _MainWindowState extends State<MainWindow> with WindowListener {
  // ── Состояние мониторинга ────────────────
  late Prefs _prefs;
  late WiFiMonitor _wifi;
  MonitorService? _monitor;
  PingService? _ping;
  StreamSubscription<MonitorEvent>? _monitorSub;
  StreamSubscription<PingResult>? _pingSub;

  // ── Состояние UI ─────────────────────────
  /// Список строк лога с уже подставленным timestamp-ом.
  final List<String> _logLines = <String>[];
  String _lastLogMessage = '';
  final ScrollController _logScroll = ScrollController();

  String _pingText = 'Ожидание...';
  Color _pingColor = AppColors.textMuted;

  String _bottomText = 'Готов к работе...';
  Color _bottomColor = AppColors.textMuted;
  FontWeight _bottomWeight = FontWeight.normal;

  bool _isRunning = false;

  @override
  void initState() {
    super.initState();
    _prefs = widget.initialPrefs;
    _wifi = _buildWifi(_prefs);

    windowManager.addListener(this);
    // Перехватываем системное закрытие, чтобы свернуть в трей.
    windowManager.setPreventClose(true);

    _initPing();
    _startMonitoring();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _monitorSub?.cancel();
    _pingSub?.cancel();
    _monitor?.dispose();
    _ping?.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  WiFiMonitor _buildWifi(Prefs p) => WiFiMonitor(
        ssid: widget.credentials.ssid,
        password: widget.credentials.password,
        routerIp: p.routerIp,
      );

  // ────────────────────────────────────────
  //  Мониторинг
  // ────────────────────────────────────────
  void _startMonitoring() {
    if (_isRunning) return;

    final service = MonitorService(
      monitor: _wifi,
      checkIntervalSec: _prefs.checkInterval,
    );
    _monitorSub = service.events.listen(_onMonitorEvent);
    service.start();
    _monitor = service;

    setState(() => _isRunning = true);
    _addStatus('Мониторинг запущен', newLine: true);
  }

  Future<void> _stopMonitoring() async {
    final svc = _monitor;
    if (svc != null) {
      await _monitorSub?.cancel();
      _monitorSub = null;
      _monitor = null;
      await svc.dispose();
    }
    if (mounted) {
      setState(() => _isRunning = false);
      _addStatus('Мониторинг остановлен', newLine: true);
    } else {
      _isRunning = false;
    }
  }

  void _initPing() {
    final svc = PingService(pingIntervalSec: _prefs.pingInterval);
    _pingSub = svc.results.listen(_onPingResult);
    svc.start();
    _ping = svc;
  }

  Future<void> _stopPing() async {
    final svc = _ping;
    if (svc == null) return;
    await _pingSub?.cancel();
    _pingSub = null;
    _ping = null;
    await svc.dispose();
  }

  // ────────────────────────────────────────
  //  Обработчики событий сервисов
  // ────────────────────────────────────────
  void _onMonitorEvent(MonitorEvent event) {
    final text = event.status.message(_wifi.ssid);

    _addStatus(text, newLine: event.statusChanged);

    // Цвет / жирность теперь идут из severity, а не из contains() по строке.
    final (color, weight) = _statusBottomStyle(event.status);
    setState(() {
      _bottomText = text;
      _bottomColor = color;
      _bottomWeight = weight;
    });

    widget.tray.setConnected(event.status.isConnected, ssid: _wifi.ssid);
  }

  (Color, FontWeight) _statusBottomStyle(MonitorStatus s) {
    switch (s.severity) {
      case StatusSeverity.ok:
        return (AppColors.statusOk, FontWeight.bold);
      case StatusSeverity.error:
        return (AppColors.statusError, FontWeight.bold);
      case StatusSeverity.warn:
        return (AppColors.statusWarn, FontWeight.bold);
      case StatusSeverity.neutral:
        return (AppColors.textMuted, FontWeight.normal);
    }
  }

  void _onPingResult(PingResult r) {
    setState(() {
      _pingText = r.label;
      _pingColor = _severityColor(r.severity);
    });
  }

  Color _severityColor(StatusSeverity s) {
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

  // ────────────────────────────────────────
  //  Лог
  // ────────────────────────────────────────
  /// Добавляет строку с timestamp-ом. Если newLine=false — заменяет последнюю
  /// строку (как cursor.removeSelectedText + insertText в Python).
  /// Дедупликация: повтор того же сообщения — только обновляем время.
  void _addStatus(String message, {bool newLine = false}) {
    final ts = _formatTime(DateTime.now());
    final formatted = '[$ts] $message';

    if (message == _lastLogMessage && _logLines.isNotEmpty) {
      _logLines[_logLines.length - 1] = formatted;
    } else if (newLine || _logLines.isEmpty) {
      _logLines.add(formatted);
      _lastLogMessage = message;
      _trimLogIfNeeded();
    } else {
      _logLines[_logLines.length - 1] = formatted;
      _lastLogMessage = message;
    }

    if (!mounted) return;
    // Запоминаем, был ли пользователь у самого низа ДО setState,
    // чтобы не «угонять» прокрутку, если он скроллит вверх читая старое.
    final stickToBottom = _isScrolledToBottom();
    setState(() {});
    if (stickToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollLogToEnd());
    }
  }

  bool _isScrolledToBottom() {
    if (!_logScroll.hasClients) return true;
    final pos = _logScroll.position;
    return pos.pixels >= pos.maxScrollExtent - 24;
  }

  void _trimLogIfNeeded() {
    if (_logLines.length <= kMaxLogLines) return;
    final excess = _logLines.length - kMaxLogLines;
    _logLines.removeRange(0, excess);
  }

  void _scrollLogToEnd() {
    if (!_logScroll.hasClients) return;
    _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
  }

  void _clearLog() {
    setState(() {
      _logLines.clear();
      _lastLogMessage = '';
    });
    _addStatus('Лог очищен', newLine: true);
  }

  String _formatTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  // ────────────────────────────────────────
  //  Настройки
  // ────────────────────────────────────────
  Future<void> _openSettings() async {
    final updated = await showPrefsDialog(context, current: _prefs);
    if (updated == null || !mounted) return;

    final old = _prefs;
    _prefs = updated;
    await widget.settings.savePrefs(updated);

    // Если поменялся интервал проверки или IP роутера — пересоздаём
    // WiFiMonitor + MonitorService (оба immutable по этим полям).
    final monitorNeedsRebuild = updated.checkInterval != old.checkInterval ||
        updated.routerIp != old.routerIp;
    if (monitorNeedsRebuild) {
      final wasRunning = _isRunning;
      await _stopMonitoring();
      _wifi = _buildWifi(_prefs);
      if (wasRunning) _startMonitoring();
    }

    // Сменился интервал пинга — пересоздаём PingService.
    if (updated.pingInterval != old.pingInterval) {
      await _stopPing();
      _initPing();
    }

    _addStatus(
      'Настройки обновлены: проверка ${updated.checkInterval} с, '
      'пинг ${updated.pingInterval} с',
      newLine: true,
    );
  }

  // ────────────────────────────────────────
  //  Закрытие окна → в трей
  // ────────────────────────────────────────
  @override
  void onWindowClose() async {
    final isPrevented = await windowManager.isPreventClose();
    if (!isPrevented) return;
    await windowManager.hide();
    widget.tray.showInfo(
      'WiFi Monitor',
      'Приложение свёрнуто в трей. Для выхода используйте меню трея.',
    );
  }

  // ────────────────────────────────────────
  //  Build
  // ────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.only(bottom: 10),
              child: Text(
                kAppTitle,
                textAlign: TextAlign.center,
                style: kTitleStyle,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Text(
                'Мониторинг сети: ${_wifi.ssid}',
                style: kInfoStyle,
              ),
            ),
            const SizedBox(height: 5),
            _buildPingFrame(),
            const SizedBox(height: 10),
            kSeparator(),
            const SizedBox(height: 10),
            Expanded(child: _buildLog()),
            const SizedBox(height: 10),
            _buildButtonsRow(),
            const SizedBox(height: 10),
            _buildBottomStatus(),
          ],
        ),
      ),
    );
  }

  Widget _buildPingFrame() {
    return Container(
      decoration: kPingFrameDecoration(),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          const Text('Ping:', style: kPingTitleStyle),
          const SizedBox(width: 6),
          Text(
            _pingText,
            style: kPingValueBaseStyle.copyWith(color: _pingColor),
          ),
        ],
      ),
    );
  }

  Widget _buildLog() {
    return Container(
      decoration: kLogDecoration(),
      padding: const EdgeInsets.all(10),
      child: Scrollbar(
        controller: _logScroll,
        thumbVisibility: true,
        child: ListView.builder(
          controller: _logScroll,
          itemCount: _logLines.length,
          itemBuilder: (ctx, i) => Text(
            _logLines[i],
            style: kLogStyle,
          ),
        ),
      ),
    );
  }

  Widget _buildButtonsRow() {
    // Декларативный список кнопок: меньше дублирования, проще менять порядок.
    final buttons = <_ToolbarButton>[
      _ToolbarButton(
        label: 'Запуск мониторинга',
        style: kButtonStart,
        onPressed: _isRunning ? null : _startMonitoring,
      ),
      _ToolbarButton(
        label: 'Остановить',
        style: kButtonStop,
        onPressed: _isRunning ? _stopMonitoring : null,
      ),
      _ToolbarButton(
        label: 'Очистить лог',
        style: kButtonClear,
        onPressed: _clearLog,
      ),
      _ToolbarButton(
        label: 'Настройки',
        style: kButtonSettings,
        onPressed: _openSettings,
      ),
    ];

    final children = <Widget>[];
    for (var i = 0; i < buttons.length; i++) {
      if (i > 0) children.add(const SizedBox(width: 8));
      children.add(Expanded(child: buttons[i].build()));
    }
    return Row(children: children);
  }

  Widget _buildBottomStatus() {
    return Container(
      padding: const EdgeInsets.only(top: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.surfaceLight)),
      ),
      child: Text(
        _bottomText,
        style: kBottomStatusBaseStyle.copyWith(
          color: _bottomColor,
          fontWeight: _bottomWeight,
        ),
      ),
    );
  }
}

/// Маленький дескриптор кнопки тулбара, чтобы не дублировать 4 одинаковых
/// блока с Expanded/ElevatedButton/Text.
class _ToolbarButton {
  final String label;
  final ButtonStyle style;
  final VoidCallback? onPressed;

  const _ToolbarButton({
    required this.label,
    required this.style,
    required this.onPressed,
  });

  Widget build() {
    return ElevatedButton(
      onPressed: onPressed,
      style: style,
      child: Text(
        label,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}
