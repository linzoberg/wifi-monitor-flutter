// ─────────────────────────────────────────────
// Data-классы и enum-ы приложения.
// Здесь намеренно нет логики — только структуры, чтобы их было удобно
// передавать между core/ и ui/ слоями.
// ─────────────────────────────────────────────

import 'constants.dart';

/// Учётные данные Wi-Fi сети.
class Credentials {
  final String ssid;
  final String password;
  final bool remember;

  const Credentials({
    required this.ssid,
    required this.password,
    required this.remember,
  });

  /// Пустые креды — используется, когда в storage ничего не сохранено.
  static const Credentials empty = Credentials(
    ssid: '',
    password: '',
    remember: false,
  );

  bool get isFilled => ssid.isNotEmpty && password.isNotEmpty;
}

/// Пользовательские настройки (интервалы + IP роутера).
/// Иммутабельный: на изменение делаем copyWith и сохраняем целиком.
class Prefs {
  final int checkInterval;
  final int pingInterval;
  final String routerIp;

  const Prefs({
    required this.checkInterval,
    required this.pingInterval,
    required this.routerIp,
  });

  /// Дефолтные значения — как в Python core/wifi.py и settings.py.
  static const Prefs defaults = Prefs(
    checkInterval: kDefaultCheckInterval,
    pingInterval: kDefaultPingInterval,
    routerIp: kDefaultRouterIp,
  );

  Prefs copyWith({
    int? checkInterval,
    int? pingInterval,
    String? routerIp,
  }) {
    return Prefs(
      checkInterval: checkInterval ?? this.checkInterval,
      pingInterval: pingInterval ?? this.pingInterval,
      routerIp: routerIp ?? this.routerIp,
    );
  }

  Map<String, dynamic> toJson() => {
        'check_interval': checkInterval,
        'ping_interval': pingInterval,
        'router_ip': routerIp,
      };

  /// Безопасный парсинг JSON с подстановкой дефолтов и зажатием в границы.
  factory Prefs.fromJson(Map<String, dynamic> json) {
    int readInt(String key, int fallback) {
      final value = json[key];
      if (value is int) return value;
      if (value is num) return value.toInt();
      if (value is String) return int.tryParse(value) ?? fallback;
      return fallback;
    }

    final raw = Prefs(
      checkInterval: readInt('check_interval', kDefaultCheckInterval),
      pingInterval: readInt('ping_interval', kDefaultPingInterval),
      routerIp: (json['router_ip'] as String?)?.trim().isNotEmpty == true
          ? (json['router_ip'] as String).trim()
          : kDefaultRouterIp,
    );

    return raw.clamped();
  }

  /// Прижимает значения к допустимым диапазонам.
  Prefs clamped() {
    int clamp(int v, int lo, int hi) =>
        v < lo ? lo : (v > hi ? hi : v);

    return Prefs(
      checkInterval:
          clamp(checkInterval, kCheckIntervalMin, kCheckIntervalMax),
      pingInterval: clamp(pingInterval, kPingIntervalMin, kPingIntervalMax),
      routerIp: routerIp.trim().isEmpty ? kDefaultRouterIp : routerIp.trim(),
    );
  }
}

/// Результат одного «такта» пинг-треда.
///
/// В Python это была строка вида "Ping 8.8.8.8: 42 мс" / "VPN is ON" /
/// "недоступен", которую UI потом парсил regex-ом. В Dart делаем нормальный
/// тип, чтобы избежать обратного парсинга.
sealed class PingResult {
  const PingResult();
}

/// Обычный ответ за `latencyMs` миллисекунд.
class PingOk extends PingResult {
  final int latencyMs;
  const PingOk(this.latencyMs);
}

/// Подозрение на VPN: ответ пришёл быстрее 1 мс.
class PingVpn extends PingResult {
  const PingVpn();
}

/// Хост недоступен / таймаут / ошибка.
class PingUnreachable extends PingResult {
  const PingUnreachable();
}

/// Состояние подключения, которое отдаёт MonitorService в UI.
sealed class MonitorStatus {
  const MonitorStatus();

  /// Является ли это «успешным подключением» — нужно для цвета иконки трея.
  bool get isConnected => false;

  /// Текстовое сообщение для лога/статусной строки.
  String message(String ssid);
}

/// Сеть видна, мы к ней подключены, интернет работает.
class StatusConnectedOnline extends MonitorStatus {
  const StatusConnectedOnline();

  @override
  bool get isConnected => true;

  @override
  String message(String ssid) => 'Подключено к $ssid, интернет доступен';
}

/// Сеть видна, подключены, но интернета нет.
class StatusConnectedOffline extends MonitorStatus {
  const StatusConnectedOffline();

  @override
  bool get isConnected => true;

  @override
  String message(String ssid) => 'Подключено к $ssid, но нет интернета';
}

/// Сеть не обнаружена в эфире.
class StatusNetworkMissing extends MonitorStatus {
  const StatusNetworkMissing();

  @override
  String message(String ssid) => 'Сеть $ssid не обнаружена';
}

/// Промежуточное состояние — мы пытаемся подключиться.
class StatusConnecting extends MonitorStatus {
  const StatusConnecting();

  @override
  String message(String ssid) => 'Обнаружена сеть $ssid, подключаюсь...';
}

/// Подключение получилось.
class StatusConnectSuccess extends MonitorStatus {
  const StatusConnectSuccess();

  @override
  bool get isConnected => true;

  @override
  String message(String ssid) => 'Успешно подключено к $ssid';
}

/// Подключение не получилось ни после одной из попыток.
class StatusConnectFailed extends MonitorStatus {
  final int attempts;
  final String lastError;

  const StatusConnectFailed({
    required this.attempts,
    required this.lastError,
  });

  @override
  String message(String ssid) =>
      'Не удалось подключиться после $attempts попыток ($lastError)';
}

/// Любая ошибка фонового цикла мониторинга.
class StatusError extends MonitorStatus {
  final String error;
  const StatusError(this.error);

  @override
  String message(String ssid) => 'Ошибка мониторинга: $error';
}

/// Технические события (старт/стоп/сообщения от UI), которые нужно
/// тоже отображать в логе с timestamp-ом.
class StatusInfo extends MonitorStatus {
  final String text;
  final bool connected;
  const StatusInfo(this.text, {this.connected = false});

  @override
  bool get isConnected => connected;

  @override
  String message(String ssid) => text;
}

/// Пакет, который MonitorService шлёт в UI:
/// - status: что произошло
/// - statusChanged: пора ли начать новую строку в логе или обновить последнюю
///   (1:1 с поведением Python add_status(message, is_new_line))
class MonitorEvent {
  final MonitorStatus status;
  final bool statusChanged;

  const MonitorEvent({
    required this.status,
    required this.statusChanged,
  });
}
