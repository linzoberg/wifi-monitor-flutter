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
//
// Что было оптимизировано (без потери функционала и без изменения дизайна):
//   • Вся логика владения сервисами/буфером лога ушла в MainWindowController
//     (ChangeNotifier). Виджет теперь только подписывается и рисует.
//   • Маппинг severity → цвет/жирность — в core/severity_palette.dart,
//     одна точка правды для нижней полосы и ping-плашки.
//   • Список кнопок построен в цикле — никаких 4 одинаковых блоков.
//   • Автоскролл лога идёт только если пользователь уже у нижней границы:
//     не «угоняет» прокрутку, когда человек читает старые строки.
// ─────────────────────────────────────────────

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../core/constants.dart';
import '../core/log_buffer.dart';
import '../core/models.dart';
import '../core/settings_service.dart';
import '../core/severity_palette.dart';
import 'main_window_controller.dart';
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
  late final MainWindowController _vm;
  final ScrollController _logScroll = ScrollController();

  @override
  void initState() {
    super.initState();

    _vm = MainWindowController(
      credentials: widget.credentials,
      initialPrefs: widget.initialPrefs,
      settings: widget.settings,
    )
      ..onConnectionChanged = _onConnectionChanged
      ..addListener(_onVmChanged);

    windowManager.addListener(this);
    // Перехватываем системное закрытие, чтобы свернуть в трей.
    windowManager.setPreventClose(true);

    _vm.start();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _vm.removeListener(_onVmChanged);
    _vm.dispose();
    _logScroll.dispose();
    super.dispose();
  }

  // ────────────────────────────────────────
  //  Реакция на изменения ViewModel
  // ────────────────────────────────────────

  void _onVmChanged() {
    if (!mounted) return;
    // Запоминаем позицию ДО ребилда, чтобы не «угнать» прокрутку.
    final stickToBottom = _isScrolledToBottom();
    setState(() {});
    if (stickToBottom) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollLogToEnd());
    }
  }

  void _onConnectionChanged(bool connected, String ssid) {
    widget.tray.setConnected(connected, ssid: ssid);
  }

  // ────────────────────────────────────────
  //  Прокрутка лога
  // ────────────────────────────────────────

  bool _isScrolledToBottom() {
    if (!_logScroll.hasClients) return true;
    final pos = _logScroll.position;
    return pos.pixels >= pos.maxScrollExtent - 24;
  }

  void _scrollLogToEnd() {
    if (!_logScroll.hasClients) return;
    _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
  }

  // ────────────────────────────────────────
  //  Действия из UI
  // ────────────────────────────────────────

  Future<void> _openSettings() async {
    final updated = await showPrefsDialog(context, current: _vm.prefs);
    if (updated == null || !mounted) return;
    await _vm.applyPrefs(updated);
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
    final ping = _vm.pingResult;
    final status = _vm.status;
    final bottomText = status.message(_vm.ssid);

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
                'Мониторинг сети: ${_vm.ssid}',
                style: kInfoStyle,
              ),
            ),
            const SizedBox(height: 5),
            _PingFrame(label: ping.label, color: severityColor(ping.severity)),
            const SizedBox(height: 10),
            kSeparator(),
            const SizedBox(height: 10),
            Expanded(child: _LogView(scroll: _logScroll, buffer: _vm.log)),
            const SizedBox(height: 10),
            _buildButtonsRow(),
            const SizedBox(height: 10),
            _BottomStatus(
              text: bottomText,
              color: severityColor(status.severity),
              weight: severityWeight(status.severity),
            ),
          ],
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
        onPressed: _vm.isRunning ? null : _vm.startMonitoring,
      ),
      _ToolbarButton(
        label: 'Остановить',
        style: kButtonStop,
        onPressed: _vm.isRunning ? () => _vm.stopMonitoring() : null,
      ),
      _ToolbarButton(
        label: 'Очистить лог',
        style: kButtonClear,
        onPressed: _vm.clearLog,
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
}

// ── Под-виджеты ─────────────────────────────

class _PingFrame extends StatelessWidget {
  final String label;
  final Color color;

  const _PingFrame({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: kPingFrameDecoration(),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          const Text('Ping:', style: kPingTitleStyle),
          const SizedBox(width: 6),
          Text(label, style: kPingValueBaseStyle.copyWith(color: color)),
        ],
      ),
    );
  }
}

class _LogView extends StatelessWidget {
  final ScrollController scroll;
  final LogBuffer buffer;

  const _LogView({required this.scroll, required this.buffer});

  @override
  Widget build(BuildContext context) {
    final lines = buffer.lines;
    return Container(
      decoration: kLogDecoration(),
      padding: const EdgeInsets.all(10),
      child: Scrollbar(
        controller: scroll,
        thumbVisibility: true,
        child: ListView.builder(
          controller: scroll,
          itemCount: lines.length,
          itemBuilder: (ctx, i) => Text(lines[i], style: kLogStyle),
        ),
      ),
    );
  }
}

class _BottomStatus extends StatelessWidget {
  final String text;
  final Color color;
  final FontWeight weight;

  const _BottomStatus({
    required this.text,
    required this.color,
    required this.weight,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: 10),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: AppColors.surfaceLight)),
      ),
      child: Text(
        text,
        style: kBottomStatusBaseStyle.copyWith(
          color: color,
          fontWeight: weight,
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
