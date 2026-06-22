// ─────────────────────────────────────────────
// Парсинг локализованных строк Windows-утилит (ping, netsh).
//
// Раньше регэкспы жили прямо в ping_service.dart / wifi_monitor.dart —
// собрал в одно место, чтобы:
//   • Их было удобно покрывать юнит-тестами без поднятия процессов.
//   • Не дублировать «знание» про русскую/английскую локаль ОС.
//
// Все паттерны toleranты к разному регистру и пробелам, потому что вывод
// netsh/ping в реальности гуляет от версии к версии.
// ─────────────────────────────────────────────

/// Время в выводе `ping`:
///   • Windows ru-RU: "время=42мс" / "время<1мс"
///   • Windows en:    "time=42ms"  / "time<1ms"
final RegExp _rePingTime = RegExp(r'(?:[Вв]ремя|[Tt]ime)\s*[=<]\s*(\d+)');

/// Признак ответа за <1мс (характерно для VPN / loopback).
final RegExp _rePingLt1 = RegExp(r'(?:[Вв]ремя|[Tt]ime)\s*<\s*1');

/// "SSID  : MyNetwork" в выводе `netsh wlan show interfaces`.
final RegExp _reSsid = RegExp(r'^\s*SSID\s*:\s*(.+)$', multiLine: true);

/// Маркеры «соединение установлено» в выводе `netsh wlan show interfaces` —
/// в зависимости от локали Windows.
const List<String> _connectedMarkers = <String>[
  'подключено',
  'connected',
];

/// Парсит миллисекунды из stdout `ping`.
/// Возвращает:
///   • число миллисекунд,
///   • `0` если ответ пришёл быстрее 1 мс (используем как «<1»),
///   • `null` если ничего не нашли (хост не ответил / нераспознанный формат).
int? parsePingTimeMs(String stdout) {
  if (stdout.isEmpty) return null;
  final m = _rePingTime.firstMatch(stdout);
  if (m != null) {
    return int.tryParse(m.group(1)!);
  }
  if (_rePingLt1.hasMatch(stdout)) return 0;
  return null;
}

/// Достаёт SSID из вывода `netsh wlan show interfaces`.
/// Возвращает trimmed имя или null, если строки нет.
String? extractCurrentSsid(String netshOutput) {
  final m = _reSsid.firstMatch(netshOutput);
  return m?.group(1)?.trim();
}

/// True, если в выводе `netsh wlan show interfaces` есть маркер «подключено».
/// Сравнение по lower-case, чтобы не зависеть от регистра.
bool containsConnectedMarker(String netshOutput) {
  final lower = netshOutput.toLowerCase();
  return _connectedMarkers.any(lower.contains);
}
