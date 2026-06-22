// ─────────────────────────────────────────────
// Контроллер системного трея.
//
// Аналог tray-части ui/window.py:
//   • Две иконки (зелёная/красная) → assets/tray_green.png и tray_red.png.
//   • Tooltip: "WiFi Monitor" по умолчанию,
//     "<SSID> — Подключено" / "Нет соединения" при обновлении состояния.
//   • Меню: "Открыть" (показ окна), разделитель, "Выход".
//   • Правый клик → контекстное меню.
//
// API:
//   final tray = TrayController(
//     onOpen: () => mainWindowController.show(),
//     onQuit: () => mainWindowController.quitApp(),
//   );
//   await tray.init();
//   await tray.setConnected(false, ssid: 'MyNet');
//   await tray.setConnected(true,  ssid: 'MyNet');
//   await tray.dispose();
//
// Заметки:
//   • setConnected() серриализует setIcon/setToolTip через _opLock,
//     чтобы быстрые подряд идущие смены состояний не наезжали друг на друга
//     (tray_manager на Windows иногда теряет последний вызов).
//   • Удалены пустые no-op методы TrayListener — миксин даёт дефолтные
//     реализации, лишний шум в файле не нужен.
// ─────────────────────────────────────────────

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import '../core/constants.dart';

class TrayController with TrayListener {

  final Future<void> Function() onOpen;
  final Future<void> Function() onQuit;

  /// Кэш состояния, чтобы избегать лишних setIcon/setToolTip.
  bool? _lastConnected;
  String _lastSsid = '';

  bool _initialized = false;

  /// Серриализует операции с трейем — иначе на быстрых сменах состояния
  /// tray_manager на Windows может проглотить последний вызов.
  Future<void> _opLock = Future<void>.value();

  TrayController({
    required this.onOpen,
    required this.onQuit,
  });

  /// Регистрирует иконку, меню и слушателей. Идемпотентно.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    trayManager.addListener(this);

    // Стартовая иконка — красная (соединение ещё не подтверждено),
    // 1:1 с Python: self.tray.setIcon(self.icon_red).
    await _runLocked(() async {
      await trayManager.setIcon(kTrayIconRed);
      await trayManager.setToolTip(kTrayDefaultTooltip);
      await trayManager.setContextMenu(_buildMenu());
    });
  }

  Menu _buildMenu() {
    return Menu(
      items: [
        MenuItem(key: 'open', label: 'Открыть'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Выход'),
      ],
    );
  }

  /// Меняет иконку + tooltip. Кэширует состояние, чтобы не дёргать систему зря.
  Future<void> setConnected(bool connected, {required String ssid}) async {
    if (!_initialized) return;

    if (_lastConnected == connected && _lastSsid == ssid) return;
    _lastConnected = connected;
    _lastSsid = ssid;

    await _runLocked(() async {
      try {
        await trayManager.setIcon(connected ? kTrayIconGreen : kTrayIconRed);
        await trayManager.setToolTip(
          connected ? '$ssid — Подключено' : '$ssid — Нет соединения',
        );
      } catch (e, st) {
        // Трей мог не успеть инициализироваться или система отозвала иконку.
        if (kDebugMode) {
          debugPrint('TrayController.setConnected error: $e\n$st');
        }
      }
    });
  }

  /// Информационный балун при сворачивании в трей. tray_manager не даёт
  /// кросс-платформенного API уведомлений, поэтому ограничиваемся debug-логом
  /// — на Windows система сама показывает балун-tooltip иконки.
  void showInfo(String title, String message) {
    if (kDebugMode) {
      debugPrint('Tray info: $title — $message');
    }
  }

  Future<void> dispose() async {
    if (!_initialized) return;
    _initialized = false;
    trayManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (_) {
      // Уже уничтожен системой — игнорируем.
    }
  }

  /// Серриализует операции с трей-менеджером, ошибки гасит сам, чтобы
  /// сбойная операция не блокировала следующие.
  Future<T> _runLocked<T>(Future<T> Function() action) {
    final next = _opLock.then((_) => action());
    _opLock = next.then<void>(
      (_) {},
      onError: (Object _) {},
    );
    return next;
  }

  // ── TrayListener ─────────────────────────

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'open':
        onOpen();
        break;
      case 'quit':
        onQuit();
        break;
    }
  }
}
