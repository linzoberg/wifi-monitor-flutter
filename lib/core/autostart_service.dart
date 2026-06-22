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
  /// В проде null → берём Platform.resolvedExecutable + --autostart.
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
  ///
  /// Раньше тут был костыль с матчингом сообщения исключения по подстрокам
  /// ("not found"/"(0x2)"). Это хрупко при смене локали Windows; теперь
  /// просто проверяем наличие значения и удаляем только если оно есть.
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
        // Удаляем только если значение реально есть — иначе считаем,
        // что задача "выключено" уже выполнена.
        if (key.getValue(kAutostartValueName) != null) {
          key.deleteValue(kAutostartValueName);
        }
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      key?.close();
    }
  }

  /// Команда для записи в реестр. На Windows — путь к .exe в кавычках
  /// плюс флаг [kAutostartArgument], чтобы при автозапуске окно НЕ всплывало,
  /// а сразу пряталось в трей (см. main.dart → _isAutostart).
  ///
  /// Под отладкой (dart/flutter run) тоже возвращаем resolvedExecutable —
  /// чтобы из реестра запускался именно тот процесс, который сейчас крутится.
  String exeCommand() {
    if (_overrideCommand != null) return _overrideCommand;
    final exe = Platform.resolvedExecutable;
    return '"$exe" $kAutostartArgument';
  }
}
