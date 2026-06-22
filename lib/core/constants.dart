// ─────────────────────────────────────────────
// Сетевые настройки и поведение приложения по умолчанию.
// 1:1 с Python: core/wifi.py (ROUTER_IP, CHECK_INTERVAL, RECONNECT_*)
//                и core/workers.py (PingThread)
// ─────────────────────────────────────────────

/// IP роутера для проверки локальной сети (TCP 80).
const String kDefaultRouterIp = '192.168.0.1';

/// Интервал проверки Wi-Fi (секунды) — дефолт.
const int kDefaultCheckInterval = 5;

/// Интервал пинга 8.8.8.8 (секунды) — дефолт.
const int kDefaultPingInterval = 5;

/// Сколько раз пытаться переподключиться при разрыве.
const int kReconnectAttempts = 100;

/// Пауза между попытками переподключения (секунды).
const int kReconnectDelay = 2;

/// Хост, который пингуем (порт 53 идёт вторым шагом проверки интернета).
const String kPingHost = '8.8.8.8';

/// Стартовая задержка пинг-треда (мс) — как в Python (INITIAL_DELAY_MS = 3000).
const int kPingInitialDelayMs = 3000;

/// Таймаут одного netsh-вызова, секунд.
const int kNetshTimeoutSec = 5;

/// Таймаут проверки текущего подключения (netsh wlan show interfaces).
const int kNetshInterfacesTimeoutSec = 3;

/// Таймаут одного TCP-коннекта при проверке интернета.
const int kInternetProbeTimeoutSec = 2;

/// Допустимые границы пользовательских настроек (защита от мусора в файле).
const int kCheckIntervalMin = 1;
const int kCheckIntervalMax = 3600;
const int kPingIntervalMin = 1;
const int kPingIntervalMax = 3600;

// ─────────────────────────────────────────────
// Идентификаторы для хранения настроек
// ─────────────────────────────────────────────

/// Имя приложения (используется в путях, реестре, secure storage).
const String kAppName = 'WiFiMonitor';

/// Сервисное имя для flutter_secure_storage (аналог KEYRING_SERVICE).
const String kKeyringService = 'WiFiMonitor';

/// Ветка реестра автозапуска.
const String kAutostartKeyPath =
    r'Software\Microsoft\Windows\CurrentVersion\Run';

/// Имя значения в ключе автозапуска.
const String kAutostartValueName = 'WiFiMonitor';

/// Имя файла настроек в %APPDATA%\WiFiMonitor\.
const String kSettingsFileName = 'settings.json';

// ─────────────────────────────────────────────
// Лог
// ─────────────────────────────────────────────

/// Лимит строк в логе главного окна (как в Python MAX_LOG_LINES).
const int kMaxLogLines = 500;
