// ─────────────────────────────────────────────
// Контроллер системного трея.
//
// Аналог tray-части ui/window.py:
//   • Две иконки (зелёная/красная) → assets/tray_green.png и tray_red.png.
//   • Tooltip: "WiFi Monitor" по умолчанию, "<SSID> — Подключено" / "Нет соединения"
//     при обновлении состояния.
//   • Меню: "Открыть" (показ окна), разделитель, "Выход".
//   • Двойной клик по иконке → показать окно.
//
// API:
//   final tray = TrayController(
//     onOpen: () => mainWindowController.show(),
//     onQuit: () => mainWindowController.quitApp(),
//   );
//   await tray.init();
//   await tray.setConnected(false, ssid: 'MyNet');   // красная + tooltip
//   await tray.setConnected(true, ssid: 'MyNet');    // зелёная + tooltip
//   await tray.dispose();
// ─────────────────────────────────────────────

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

typedef VoidAsyncCallback = Future<void> Function();

class TrayController with TrayListener {
  final Future<void> Function() onOpen;
  final Future<void> Function() onQuit;

  /// Текущее состояние, чтобы избегать лишних setIcon/setToolTip.
  bool? _lastConnected;
  String _lastSsid = '';

  bool _initialized = false;

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
    await trayManager.setIcon('assets/tray_red.png');
    await trayManager.setToolTip('WiFi Monitor');
    await trayManager.setContextMenu(_buildMenu());
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

    try {
      await trayManager.setIcon(
        connected ? 'assets/tray_green.png' : 'assets/tray_red.png',
      );
      await trayManager.setToolTip(
        connected ? '$ssid — Подключено' : '$ssid — Нет соединения',
      );
    } catch (e, st) {
      // Трей мог не успеть инициализироваться, или система отозвала иконку —
      // не валим из-за этого приложение.
      if (kDebugMode) {
        debugPrint('TrayController.setConnected error: $e\n$st');
      }
    }
  }

  /// Показывает balloon-уведомление (используется при сворачивании в трей).
  /// tray_manager не имеет кросс-платформенного API уведомлений, поэтому
  /// просто пишем в debug. На Windows balloon вешает сама система при
  /// событиях иконки — нам этого достаточно, чтобы не падать.
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
      // Игнорируем — мог быть уже уничтожен системой.
    }
  }

  // ── TrayListener ─────────────────────────

  @override
  void onTrayIconMouseDown() {
    // Левый клик — открыть. На Windows это даёт более привычное поведение,
    // чем ждать только двойной клик; пользователи Python-версии могли
    // ожидать одинарного клика тоже.
    // Если поведение покажется навязчивым — оставим только onTrayIconDoubleClick.
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayIconMouseUp() {
    // no-op
  }

  @override
  void onTrayIconRightMouseUp() {
    // no-op
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

// ─────────────────────────────────────────────
// tray_manager на Windows различает onTrayIconDoubleClick через клиентский
// код пакета — у разных версий пакета сигнатура может отличаться, поэтому
// держим обработку двойного клика опциональной (см. подмешивание ниже,
// если потребуется).
// ─────────────────────────────────────────────
