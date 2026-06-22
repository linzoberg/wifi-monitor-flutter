// ─────────────────────────────────────────────
// Хранение пользовательских настроек и учётных данных.
//
// Аналог core/settings.py:
//   • SSID + флаг "запомнить" + Prefs → JSON в
//        %APPDATA%\WiFiMonitor\settings.json
//     (в Python это был QSettings / реестр; здесь — простой файл,
//      т.к. Flutter нативного QSettings не имеет, а JSON удобнее
//      и для будущего Android-порта).
//   • Пароль                          → flutter_secure_storage
//     (на Windows это Credential Manager + DPAPI — ровно то же, что
//      keyring в Python).
//
// API:
//   final svc = SettingsService();
//   final creds = await svc.loadCredentials();
//   await svc.saveCredentials(ssid, password);
//   await svc.forgetCredentials();
//
//   final prefs = await svc.loadPrefs();
//   await svc.savePrefs(prefs);
//
// Все методы безопасны к ошибкам ввода/вывода: при любом сбое
// возвращают пустые/дефолтные значения, как делал Python.
// ─────────────────────────────────────────────

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'constants.dart';
import 'models.dart';

/// Ключи в JSON-файле настроек. Названия совпадают с Python QSettings:
///   remember, ssid, check_interval, ping_interval, router_ip.
class _JsonKeys {
  static const remember = 'remember';
  static const ssid = 'ssid';
  static const checkInterval = 'check_interval';
  static const pingInterval = 'ping_interval';
  static const routerIp = 'router_ip';
}

/// Сервис настроек. Безопасно вызывать методы параллельно: внутри один
/// внутренний lock на файл, чтобы не словить гонку при одновременных
/// load/save из UI.
class SettingsService {
  /// Подменяемое хранилище паролей (для тестов).
  final FlutterSecureStorage _secure;

  /// Подменяемая директория настроек (для тестов). В проде = %APPDATA%\<app>.
  final Directory? _overrideDir;

  /// Сериализуем файловые операции, чтобы не было гонки чтение/запись.
  /// Обновляем цепочку, но делаем это через .catchError(_) — чтобы ошибка в одной
  /// задаче не ломала все последующие, а прокидывалась именно
  /// вызвавшему.
  Future<void> _ioLock = Future<void>.value();

  SettingsService({
    FlutterSecureStorage? secureStorage,
    Directory? overrideDirectory,
  })  : _secure = secureStorage ??
            const FlutterSecureStorage(
              wOptions: WindowsOptions(useBackwardCompatibility: true),
            ),
        _overrideDir = overrideDirectory;

  // ── Учётные данные ──────────────────────────

  /// Возвращает (ssid, password, remember). Если что-то не сохранено или
  /// произошла ошибка — пустые значения (как Python).
  Future<Credentials> loadCredentials() async {
    final json = await _readJson();
    final remember = _readBool(json, _JsonKeys.remember, false);
    if (!remember) return Credentials.empty;

    final ssid = _readString(json, _JsonKeys.ssid, '');
    if (ssid.isEmpty) {
      return const Credentials(ssid: '', password: '', remember: true);
    }

    String password = '';
    try {
      password = await _secure.read(key: _keyringKey(ssid)) ?? '';
    } catch (_) {
      password = '';
    }
    return Credentials(ssid: ssid, password: password, remember: true);
  }

  /// Сохраняет учётные данные: SSID в JSON, пароль в secure storage.
  /// remember выставляется в true (как save_credentials в Python).
  Future<void> saveCredentials(String ssid, String password) async {
    return _runLocked(() async {
      final json = await _readJson();
      json[_JsonKeys.remember] = true;
      json[_JsonKeys.ssid] = ssid;
      await _writeJson(json);

      try {
        await _secure.write(key: _keyringKey(ssid), value: password);
      } catch (_) {
        // как в Python — молча игнорируем ошибки keyring
      }
    });
  }

  /// Забыть учётные данные: remember=false, SSID удаляется,
  /// пароль удаляется из secure storage.
  Future<void> forgetCredentials() async {
    return _runLocked(() async {
      final json = await _readJson();
      final oldSsid = _readString(json, _JsonKeys.ssid, '');
      json[_JsonKeys.remember] = false;
      json.remove(_JsonKeys.ssid);
      await _writeJson(json);

      if (oldSsid.isNotEmpty) {
        try {
          await _secure.delete(key: _keyringKey(oldSsid));
        } catch (_) {/* как в Python — пофиг */}
      }
    });
  }

  // ── Пользовательские настройки ──────────────

  /// Загружает Prefs, подставляя дефолты и зажимая значения в границы.
  Future<Prefs> loadPrefs() async {
    final json = await _readJson();
    return Prefs.fromJson({
      'check_interval':
          json[_JsonKeys.checkInterval] ?? kDefaultCheckInterval,
      'ping_interval':
          json[_JsonKeys.pingInterval] ?? kDefaultPingInterval,
      'router_ip': json[_JsonKeys.routerIp] ?? kDefaultRouterIp,
    });
  }

  /// Сохраняет Prefs в JSON-файл. Остальные поля (ssid/remember) не трогаем.
  Future<void> savePrefs(Prefs prefs) async {
    final clean = prefs.clamped();
    return _runLocked(() async {
      final json = await _readJson();
      json[_JsonKeys.checkInterval] = clean.checkInterval;
      json[_JsonKeys.pingInterval] = clean.pingInterval;
      json[_JsonKeys.routerIp] = clean.routerIp;
      await _writeJson(json);
    });
  }

  // ── Пути и I/O ──────────────────────────────

  /// Путь к директории %APPDATA%\<kAppName>\.
  /// На не-Windows fallback в support directory — пригодится для тестов.
  Future<Directory> _settingsDir() async {
    if (_overrideDir != null) return _overrideDir;

    Directory base;
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        base = Directory(appData);
      } else {
        base = await getApplicationSupportDirectory();
      }
    } else {
      base = await getApplicationSupportDirectory();
    }

    final dir = Directory('${base.path}${Platform.pathSeparator}$kAppName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _settingsFile() async {
    final dir = await _settingsDir();
    return File('${dir.path}${Platform.pathSeparator}$kSettingsFileName');
  }

  /// Безопасное чтение JSON: всегда возвращает Map, никаких исключений
  /// наружу. Если файла нет / он битый — пустой Map.
  Future<Map<String, Object?>> _readJson() async {
    try {
      final file = await _settingsFile();
      if (!await file.exists()) return <String, Object?>{};
      final text = await file.readAsString();
      if (text.trim().isEmpty) return <String, Object?>{};
      final decoded = jsonDecode(text);
      if (decoded is Map) return decoded.cast<String, Object?>();
      return <String, Object?>{};
    } catch (_) {
      return <String, Object?>{};
    }
  }

  /// Безопасная запись: пишем во временный файл, затем атомарно
  /// переименовываем. Минимизирует риск получить битый JSON
  /// при падении/перезагрузке посреди записи.
  Future<void> _writeJson(Map<String, Object?> json) async {
    try {
      final file = await _settingsFile();
      final tmp = File('${file.path}.tmp');
      const encoder = JsonEncoder.withIndent('  ');
      await tmp.writeAsString(encoder.convert(json), flush: true);
      if (await file.exists()) {
        try {
          await file.delete();
        } catch (_) {/* перезапишется через rename */}
      }
      await tmp.rename(file.path);
    } catch (_) {
      // Сохранение не критично для работы — Python тоже не падает на этом.
    }
  }

  /// Последовательное выполнение I/O-операций. Ошибка в action доходит до вызывающего,
  /// но не ломает цепочку для следующих вызовов.
  Future<T> _runLocked<T>(Future<T> Function() action) {
    final next = _ioLock.then((_) => action());
    // Свапаем цепочку всегда, даже если next упадёт (поглощаем ошибку
    // прямо в _ioLock, чтобы следующий .then() не подхватывал чужой fail).
    _ioLock = next.then<void>(
      (_) {},
      onError: (Object _) {},
    );
    return next;
  }

  // ── Хелперы для парсинга JSON ───────────────

  static bool _readBool(Map<String, Object?> json, String key, bool fallback) {
    final v = json[key];
    if (v is bool) return v;
    if (v is num) return v != 0;
    if (v is String) {
      final lower = v.toLowerCase();
      if (lower == 'true' || lower == '1') return true;
      if (lower == 'false' || lower == '0' || lower.isEmpty) return false;
    }
    return fallback;
  }

  static String _readString(
    Map<String, Object?> json,
    String key,
    String fallback,
  ) {
    final v = json[key];
    if (v is String) return v;
    if (v == null) return fallback;
    return v.toString();
  }

  /// Ключ в secure storage. Включает SSID — так же, как keyring в Python
  /// хранил пароль под (service=WiFiMonitor, username=ssid).
  String _keyringKey(String ssid) => '$kKeyringService/$ssid';
}
