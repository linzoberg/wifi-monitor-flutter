// ─────────────────────────────────────────────
// Управление и мониторинг Wi-Fi подключения через netsh (Windows).
// Аналог core/wifi.py → класс WiFiMonitor.
//
// API максимально совпадает с Python-версией:
//   checkWifiAvailable()    → bool
//   getCurrentConnection()  → bool
//   connectToWifi()         → ConnectResult(ok, message)
//   checkInternet()         → bool
// ─────────────────────────────────────────────

import 'dart:async';
import 'dart:io';

import 'constants.dart';
import 'process_runner.dart';

/// Маркеры активного подключения в выводе `netsh wlan show interfaces`.
/// На разных локалях Windows строка отличается — держим набор.
const List<String> _kConnectedMarkers = ['подключено', 'connected'];

/// Regex для строки вида:  SSID                   : MyNetwork
/// Соответствует Python _RE_SSID = r'^\s*SSID\s*:\s*(.+)$'.
final RegExp _kRegSsid = RegExp(
  r'^\s*SSID\s*:\s*(.+)$',
  multiLine: true,
);

/// Результат одной попытки подключения.
class ConnectResult {
  final bool ok;
  final String message;
  const ConnectResult(this.ok, this.message);
}

/// Мониторинг и управление подключением к Wi-Fi.
///
/// Класс хранит сам набор данных (SSID/пароль/IP роутера) и кеширует
/// последние известные состояния — как и Python-оригинал.
class WiFiMonitor {
  final String ssid;
  final String password;

  /// IP роутера для проверки локальной сети (можно менять на лету —
  /// в Python это поле тоже мутабельное).
  String routerIp;

  /// Кеш: подключены ли мы сейчас к нужной сети.
  bool connected = false;

  /// Кеш: видна ли сеть в эфире.
  bool ssidAvailable = false;

  WiFiMonitor({
    required this.ssid,
    required this.password,
    String? routerIp,
  }) : routerIp = routerIp ?? kDefaultRouterIp;

  // ── Сканирование сетей ───────────────────────
  /// Проверяет, видна ли указанная сеть в эфире.
  Future<bool> checkWifiAvailable() async {
    HiddenProcessResult result;
    try {
      result = await runHidden(
        'netsh',
        ['wlan', 'show', 'networks'],
        timeout: const Duration(seconds: kNetshTimeoutSec),
      );
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }

    if (!result.ok || result.stdout.isEmpty) {
      return false;
    }

    ssidAvailable = result.stdout.contains(ssid);
    return ssidAvailable;
  }

  // ── Текущее подключение ──────────────────────
  /// Проверяет, что мы реально подключены к нужной сети.
  Future<bool> getCurrentConnection() async {
    HiddenProcessResult result;
    try {
      result = await runHidden(
        'netsh',
        ['wlan', 'show', 'interfaces'],
        timeout: const Duration(seconds: kNetshInterfacesTimeoutSec),
      );
    } on TimeoutException {
      connected = false;
      return false;
    } catch (_) {
      connected = false;
      return false;
    }

    if (!result.ok || result.stdout.isEmpty) {
      connected = false;
      return false;
    }

    final output = result.stdout;
    final ssidMatch = _kRegSsid.firstMatch(output);
    final currentSsid = ssidMatch?.group(1)?.trim();

    final outputLower = output.toLowerCase();
    final isConnected = _kConnectedMarkers.any(outputLower.contains);

    connected = currentSsid == ssid && isConnected;
    return connected;
  }

  // ── Подключение к Wi-Fi ──────────────────────
  /// Сборка XML-профиля WLAN. 1:1 со строкой из Python (_build_profile_xml).
  String _buildProfileXml() {
    return '<?xml version="1.0"?>\n'
        '<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">\n'
        '    <name>$ssid</name>\n'
        '    <SSIDConfig>\n'
        '        <SSID>\n'
        '            <name>$ssid</name>\n'
        '        </SSID>\n'
        '    </SSIDConfig>\n'
        '    <connectionType>ESS</connectionType>\n'
        '    <connectionMode>auto</connectionMode>\n'
        '    <MSM>\n'
        '        <security>\n'
        '            <authEncryption>\n'
        '                <authentication>WPA2PSK</authentication>\n'
        '                <encryption>AES</encryption>\n'
        '                <useOneX>false</useOneX>\n'
        '            </authEncryption>\n'
        '            <sharedKey>\n'
        '                <keyType>passPhrase</keyType>\n'
        '                <protected>false</protected>\n'
        '                <keyMaterial>$password</keyMaterial>\n'
        '            </sharedKey>\n'
        '        </security>\n'
        '    </MSM>\n'
        '</WLANProfile>\n';
  }

  /// Одна попытка установить соединение.
  /// Возвращает `ConnectResult(ok, errorDescription)` — в случае успеха
  /// `message` пустой, как и в Python.
  Future<ConnectResult> _tryConnectOnce() async {
    File? tempFile;
    try {
      // 1. Удаляем старый профиль (ошибки игнорируем)
      try {
        await runHidden(
          'netsh',
          ['wlan', 'delete', 'profile', 'name=$ssid'],
          timeout: const Duration(seconds: kNetshTimeoutSec),
        );
      } catch (_) {
        // как в Python — пофиг
      }

      // 2. Создаём временный XML-файл с профилем
      final tempDir = Directory.systemTemp;
      final sep = Platform.pathSeparator;
      tempFile = await File(
        '${tempDir.path}${sep}wifi_${DateTime.now().microsecondsSinceEpoch}.xml',
      ).create();
      await tempFile.writeAsString(_buildProfileXml(), flush: true);

      // 3. Добавляем профиль
      await runHidden(
        'netsh',
        ['wlan', 'add', 'profile', 'filename=${tempFile.path}'],
        timeout: const Duration(seconds: kNetshTimeoutSec),
      );

      // 4. Подключаемся
      final connectResult = await runHidden(
        'netsh',
        ['wlan', 'connect', 'name=$ssid'],
        timeout: const Duration(seconds: kNetshTimeoutSec),
      );

      if (!connectResult.ok) {
        return const ConnectResult(false, 'ошибка команды подключения');
      }

      final connected = await _waitForConnection(
        timeout: const Duration(seconds: 5),
        poll: const Duration(milliseconds: 500),
      );
      if (connected) {
        return const ConnectResult(true, '');
      }
      return const ConnectResult(false, 'не удалось установить соединение');
    } on TimeoutException catch (e) {
      return ConnectResult(false, 'таймаут: ${e.message ?? "истёк"}');
    } catch (e) {
      return ConnectResult(false, 'ошибка: $e');
    } finally {
      // Удаляем временный файл (ошибки удаления игнорируем — как в Python)
      if (tempFile != null) {
        try {
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (_) {/* ignore */}
      }
    }
  }

  /// Пытается подключиться, с повторами по конфигу.
  /// Возвращает финальный результат после всех попыток.
  Future<ConnectResult> connectToWifi() async {
    String lastError = '';

    for (var attempt = 1; attempt <= kReconnectAttempts; attempt++) {
      final result = await _tryConnectOnce();
      if (result.ok) {
        return ConnectResult(true, 'Успешно подключено к $ssid');
      }

      lastError = 'Попытка $attempt/$kReconnectAttempts: ${result.message}';

      if (attempt < kReconnectAttempts) {
        await Future<void>.delayed(const Duration(seconds: kReconnectDelay));
      }
    }

    return ConnectResult(
      false,
      'Не удалось подключиться после $kReconnectAttempts попыток ($lastError)',
    );
  }

  /// Активно ждёт подключения вместо фиксированной паузы.
  Future<bool> _waitForConnection({
    required Duration timeout,
    required Duration poll,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await getCurrentConnection()) {
        return true;
      }
      await Future<void>.delayed(poll);
    }
    return false;
  }

  // ── Интернет ─────────────────────────────────
  /// Доступен ли интернет: пробуем роутер, затем DNS Google.
  Future<bool> checkInternet() async {
    final probes = [
      _Probe(routerIp, 80),
      const _Probe('8.8.8.8', 53),
    ];
    for (final probe in probes) {
      try {
        final socket = await Socket.connect(
          probe.host,
          probe.port,
          timeout: const Duration(seconds: kInternetProbeTimeoutSec),
        );
        socket.destroy();
        return true;
      } catch (_) {
        continue;
      }
    }
    return false;
  }
}

class _Probe {
  final String host;
  final int port;
  const _Probe(this.host, this.port);
}
