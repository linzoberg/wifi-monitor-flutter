// ─────────────────────────────────────────────
// Автозапуск через HKCU\Software\Microsoft\Windows\CurrentVersion\Run.
//
// Аналог core/settings.py → is_autostart_enabled / set_autostart / _exe_command.
// На Windows используется пакет win32_registry; на других платформах
// методы возвращают безопасные значения (false / true), чтобы UI не падал
// в случае запуска из-под dart test или для будущего Android-порта.
//
// API:
//   final svc = AutostartService();
//   final on = await svc.isEnabled();
//   final ok = await svc.setEnabled(true);
//   final cmd = svc.exeCommand();      // строка, которую кладём в реестр
// ─────────────────────────────────────────────

import 'dart:io';

import 'package:win32_registry/win32_registry.dart';

import 'constants.dart';

class AutostartService {
  /// Переопределение команды запуска (для тестов или ручной правки путей).
  /// В проде null → берём Platform.resolvedExecutable.
  final String? _overrideCommand;

  const AutostartService({String? overrideCommand})
      : _overrideCommand = overrideCommand;

  /// Включён ли автозапуск (есть ли значение в HKCU\...\Run).
  /// На не-Windows платформах — всегда false.
  Future<bool> isEnabled() async {
    if (!Platform.isWindows) return false;
    RegistryKey? key;
    try {
      key = Registry.openPath(
        RegistryHive.currentUser,
        path: kAutostartKeyPath,
        desiredAccessRights: AccessRights.readOnly,
      );
      final value = key.getValue(kAutostartValueName);
      if (value == null) return false;
      final data = value.data;
      if (data is String) return data.trim().isNotEmpty;
      return true;
    } catch (_) {
      return false;
    } finally {
      key?.close();
    }
  }

  /// Включает/выключает автозапуск. Возвращает true при успехе.
  /// При выключении отсутствие значения трактуем как успех (как Python).
  Future<bool> setEnabled(bool enabled) async {
    if (!Platform.isWindows) return true; // тихий no-op
    RegistryKey? key;
    try {
      key = Registry.openPath(
        RegistryHive.currentUser,
        path: kAutostartKeyPath,
        desiredAccessRights: AccessRights.allAccess,
      );

      if (enabled) {
        key.createValue(
          RegistryValue(
            kAutostartValueName,
            RegistryValueType.string,
            exeCommand(),
          ),
        );
      } else {
        try {
          key.deleteValue(kAutostartValueName);
        } catch (e) {
          // ERROR_FILE_NOT_FOUND (2) — значит уже выключено, это норм.
          // win32_registry бросает WindowsException, но публично его
          // не экспортирует, поэтому проверяем по сообщению/коду
          // через duck-typing и просто игнорируем «не найдено».
          final msg = e.toString().toLowerCase();
          final notFound = msg.contains('not found') ||
              msg.contains('cannot find') ||
              msg.contains('(0x2)') ||
              msg.contains(' 2)') ||
              msg.contains('error_file_not_found');
          if (!notFound) rethrow;
        }
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      key?.close();
    }
  }

  /// Команда для записи в реестр. На Windows — путь к .exe в кавычках.
  /// Под отладкой (dart/flutter run) тоже возвращаем resolvedExecutable —
  /// чтобы из реестра запускался именно тот процесс, который сейчас крутится.
  String exeCommand() {
    if (_overrideCommand != null) return _overrideCommand;
    final exe = Platform.resolvedExecutable;
    return '"$exe"';
  }
}
