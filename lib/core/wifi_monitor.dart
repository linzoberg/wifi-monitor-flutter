// ─────────────────────────────────────────────
// Управление и мониторинг Wi-Fi подключения через netsh (Windows).
// 1:1 порт core/wifi.py:
//   • check_wifi_available()    — netsh wlan show networks + поиск SSID
//   • get_current_connection()  — netsh wlan show interfaces + парсинг
//   • connect_to_wifi()         — delete profile → add profile (XML) → connect
//   • check_internet()          — TCP-проба роутера, затем 8.8.8.8:53
//
// Сетевые «магические» числа лежат в constants.dart, чтобы не дублировать.
// ─────────────────────────────────────────────

import 'dart:async';
import 'dart:io';

import 'constants.dart';
import 'models.dart';
import 'process_runner.dart';

/// SSID:  MyNetwork
/// (без двоеточия в значении — берём всё до конца строки)
final RegExp _reSsid =
    RegExp(r'^\s*SSID\s*:\s*(.+)$', multiLine: true);

/// Признаки «connected» в выводе `netsh wlan show interfaces` —
/// в разных локалях Windows строка отличается.
const List<String> _connectedMarkers = <String>[
  'подключено',
  'connected',
];

/// Мониторинг и управление Wi-Fi.
///
/// Состояние [connected] / [ssidAvailable] — это снапшот последнего опроса,
/// как и в Python. UI читает их напрямую при необходимости, но основной поток
/// данных всё равно идёт через MonitorService → Stream<MonitorEvent>.
class WiFiMonitor {
  final String ssid;
  final String password;
  final String routerIp;

  bool connected = false;
  bool ssidAvailable = false;

  WiFiMonitor({
    required this.ssid,
    required this.password,
    String? routerIp,
  }) : routerIp = (routerIp == null || routerIp.trim().isEmpty)
            ? kDefaultRouterIp
            : routerIp.trim();

  // ── Сканирование сетей ────────────────────

  /// Возвращает true, если нужный SSID виден в эфире.
  /// Реализация — как в Python: ищем подстроку в полном выводе netsh.
  Future<bool> checkWifiAvailable() async {
    final HiddenProcessResult result;
    try {
      result = await runHidden(
        'netsh',
        const ['wlan', 'show', 'networks'],
        timeout: const Duration(seconds: kNetshTimeoutSec),
      );
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }

    if (!result.ok || result.stdout.isEmpty) {
      ssidAvailable = false;
      return false;
    }

    ssidAvailable = result.stdout.contains(ssid);
    return ssidAvailable;
  }

  // ── Текущее подключение ───────────────────

  /// True если ОС подключена именно к [ssid].
  Future<bool> getCurrentConnection() async {
    final HiddenProcessResult result;
    try {
      result = await runHidden(
        'netsh',
        const ['wlan', 'show', 'interfaces'],
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
    final match = _reSsid.firstMatch(output);
    final currentSsid = match?.group(1)?.trim();

    final lower = output.toLowerCase();
    final isConnected = _connectedMarkers.any(lower.contains);

    connected = currentSsid == ssid && isConnected;
    return connected;
  }

  // ── Подключение к Wi-Fi ───────────────────

  /// Профиль WPA2-PSK / AES — формат и порядок тегов 1:1 с Python.
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

  /// Одна попытка подключения. Возвращает (успех, текст ошибки).
  Future<({bool ok, String error})> _tryConnectOnce() async {
    File? tempFile;
    try {
      // Удаляем старый профиль (ошибки игнорируем — его могло и не быть).
      try {
        await runHidden(
          'netsh',
          ['wlan', 'delete', 'profile', 'name=$ssid'],
          timeout: const Duration(seconds: kNetshTimeoutSec),
        );
      } catch (_) {/* ok */}

      // Временный XML-файл с профилем (UTF-8).
      final dir = Directory.systemTemp;
      tempFile = await File(
        '${dir.path}${Platform.pathSeparator}'
        'wifi_${DateTime.now().microsecondsSinceEpoch}.xml',
      ).create();
      await tempFile.writeAsString(_buildProfileXml());

      // Добавляем профиль.
      await runHidden(
        'netsh',
        ['wlan', 'add', 'profile', 'filename=${tempFile.path}'],
        timeout: const Duration(seconds: kNetshTimeoutSec),
      );

      // Подключаемся.
      final connectResult = await runHidden(
        'netsh',
        ['wlan', 'connect', 'name=$ssid'],
        timeout: const Duration(seconds: kNetshTimeoutSec),
      );

      if (!connectResult.ok) {
        return (ok: false, error: 'ошибка команды подключения');
      }

      final ok = await _waitForConnection(
        timeout: const Duration(seconds: 5),
        poll: const Duration(milliseconds: 500),
      );
      if (ok) return (ok: true, error: '');
      return (ok: false, error: 'не удалось установить соединение');
    } on TimeoutException catch (e) {
      return (ok: false, error: 'ошибка: $e');
    } catch (e) {
      return (ok: false, error: 'ошибка: $e');
    } finally {
      if (tempFile != null) {
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {/* ok */}
      }
    }
  }

  /// Серия попыток подключения с паузами между ними.
  /// Возвращает структуру с финальным результатом — UI/Monitor строит
  /// нужный статус сам, без обратного парсинга строки.
  Future<ConnectAttemptOutcome> connectToWifi() async {
    const maxAttempts = kReconnectAttempts;
    var lastError = '';
    var lastAttempt = 0;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      lastAttempt = attempt;
      final result = await _tryConnectOnce();
      if (result.ok) {
        return ConnectAttemptOutcome(
          success: true,
          attempts: attempt,
          lastError: '',
        );
      }
      lastError = result.error;

      if (attempt < maxAttempts) {
        await Future<void>.delayed(
          const Duration(seconds: kReconnectDelay),
        );
      }
    }

    return ConnectAttemptOutcome(
      success: false,
      attempts: lastAttempt,
      lastError: lastError,
    );
  }

  /// Активное ожидание установления соединения.
  Future<bool> _waitForConnection({
    required Duration timeout,
    required Duration poll,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await getCurrentConnection()) return true;
      await Future<void>.delayed(poll);
    }
    return false;
  }

  // ── Интернет ──────────────────────────────

  /// Двухступенчатая проверка интернета: роутер (80) → 8.8.8.8 (53).
  /// Используем TCP-соединение, как socket.create_connection в Python.
  Future<bool> checkInternet() async {
    final probes = <(String, int)>[
      (routerIp, 80),
      ('8.8.8.8', 53),
    ];

    for (final (host, port) in probes) {
      try {
        final socket = await Socket.connect(
          host,
          port,
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
