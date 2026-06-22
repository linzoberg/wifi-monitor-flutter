// ─────────────────────────────────────────────
// Запуск внешних процессов (netsh, ping) со скрытым окном консоли
// и аккуратным декодированием вывода в кириллице.
//
// Аналог core/wifi.py → run_hidden() + STARTUPINFO + CREATE_NO_WINDOW.
//
// Особенности Windows:
//   • Process.start() в Flutter Windows app в большинстве случаев не показывает
//     консольное окно для дочерних ping/netsh, потому что Flutter runner —
//     WIN32 app без своей консоли (CONSOLE_NONE). Но этого недостаточно
//     на 100%: в редких случаях (особенно ping) может мелькнуть чёрный
//     прямоугольник. По-хорошему нужен флаг CREATE_NO_WINDOW через
//     CreateProcessW (package:win32). Сейчас этого не делаем, чтобы
//     не раздувать зависимости; TODO ниже — на будущее.
//   • Кодировка stdout кириллических утилит = CP866 (OEM). Поэтому ловим
//     байты (stdoutEncoding: null) и декодируем вручную через таблицу.
//
// TODO(win32): впилить нативный CreateProcessW с CREATE_NO_WINDOW |
//   DETACHED_PROCESS, когда появится реальный репорт о мелькающей
//   консоли. Сейчас пользователи не жаловались.
// ─────────────────────────────────────────────

import 'dart:async';
import 'dart:io';

/// Результат запуска процесса.
/// Похож на subprocess.CompletedProcess из Python.
class HiddenProcessResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  const HiddenProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// True если процесс отработал и код возврата = 0.
  bool get ok => exitCode == 0;
}

/// Запуск процесса со скрытым окном.
///
/// [executable] — имя или путь exe (например, 'netsh', 'ping').
/// [arguments] — список аргументов.
/// [timeout]   — таймаут; по истечении процесс убивается и кидается TimeoutException.
///               Если null — без таймаута. Дефолта нет нарочно: каждый вызов
///               должен явно решить, сколько ждать (netsh add profile и ping
///               — разные истории).
Future<HiddenProcessResult> runHidden(
  String executable,
  List<String> arguments, {
  required Duration? timeout,
}) async {
  Process process;
  try {
    process = await Process.start(
      executable,
      arguments,
      runInShell: false,
      // detached/normal не подходят — нужен stdout/stderr.
      mode: ProcessStartMode.normal,
    );
  } on ProcessException catch (e) {
    return HiddenProcessResult(
      exitCode: e.errorCode == 0 ? 1 : e.errorCode,
      stdout: '',
      stderr: e.message,
    );
  }

  // Собираем сырые байты, чтобы декодировать самим (CP866).
  final stdoutBytes = <int>[];
  final stderrBytes = <int>[];
  final stdoutSub = process.stdout.listen(stdoutBytes.addAll);
  final stderrSub = process.stderr.listen(stderrBytes.addAll);

  Timer? killTimer;
  var timedOut = false;
  if (timeout != null) {
    killTimer = Timer(timeout, () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
    });
  }

  final exitCode = await process.exitCode;
  killTimer?.cancel();

  // Дочитываем оба потока (.cancel() возвращает Future).
  await stdoutSub.cancel();
  await stderrSub.cancel();

  if (timedOut) {
    throw TimeoutException(
      'Process "$executable ${arguments.join(' ')}" timed out',
      timeout,
    );
  }

  return HiddenProcessResult(
    exitCode: exitCode,
    stdout: _decodeCp866(stdoutBytes),
    stderr: _decodeCp866(stderrBytes),
  );
}

// ─────────────────────────────────────────────
// CP866 (OEM 866 / Cyrillic) → String
// Эта кодировка используется в выводе ping/netsh на русской Windows.
// dart:convert её не умеет, поэтому таблица — здесь.
// Только верхняя половина (0x80..0xFF); нижняя — это ASCII as-is.
// ─────────────────────────────────────────────

const List<int> _cp866Upper = <int>[
  // 0x80..0x8F : А Б В Г Д Е Ж З И Й К Л М Н О П
  0x0410, 0x0411, 0x0412, 0x0413, 0x0414, 0x0415, 0x0416, 0x0417,
  0x0418, 0x0419, 0x041A, 0x041B, 0x041C, 0x041D, 0x041E, 0x041F,
  // 0x90..0x9F : Р С Т У Ф Х Ц Ч Ш Щ Ъ Ы Ь Э Ю Я
  0x0420, 0x0421, 0x0422, 0x0423, 0x0424, 0x0425, 0x0426, 0x0427,
  0x0428, 0x0429, 0x042A, 0x042B, 0x042C, 0x042D, 0x042E, 0x042F,
  // 0xA0..0xAF : а б в г д е ж з и й к л м н о п
  0x0430, 0x0431, 0x0432, 0x0433, 0x0434, 0x0435, 0x0436, 0x0437,
  0x0438, 0x0439, 0x043A, 0x043B, 0x043C, 0x043D, 0x043E, 0x043F,
  // 0xB0..0xBF : псевдографика (рамки)
  0x2591, 0x2592, 0x2593, 0x2502, 0x2524, 0x2561, 0x2562, 0x2556,
  0x2555, 0x2563, 0x2551, 0x2557, 0x255D, 0x255C, 0x255B, 0x2510,
  // 0xC0..0xCF : псевдографика
  0x2514, 0x2534, 0x252C, 0x251C, 0x2500, 0x253C, 0x255E, 0x255F,
  0x255A, 0x2554, 0x2569, 0x2566, 0x2560, 0x2550, 0x256C, 0x2567,
  // 0xD0..0xDF : псевдографика
  0x2568, 0x2564, 0x2565, 0x2559, 0x2558, 0x2552, 0x2553, 0x256B,
  0x256A, 0x2518, 0x250C, 0x2588, 0x2584, 0x258C, 0x2590, 0x2580,
  // 0xE0..0xEF : р с т у ф х ц ч ш щ ъ ы ь э ю я
  0x0440, 0x0441, 0x0442, 0x0443, 0x0444, 0x0445, 0x0446, 0x0447,
  0x0448, 0x0449, 0x044A, 0x044B, 0x044C, 0x044D, 0x044E, 0x044F,
  // 0xF0..0xFF : Ё ё Є є Ї ї Ў ў ° ∙ · √ № ¤ ■ NBSP
  0x0401, 0x0451, 0x0404, 0x0454, 0x0407, 0x0457, 0x040E, 0x045E,
  0x00B0, 0x2219, 0x00B7, 0x221A, 0x2116, 0x00A4, 0x25A0, 0x00A0,
];

String _decodeCp866(List<int> bytes) {
  if (bytes.isEmpty) return '';
  final buf = StringBuffer();
  for (final b in bytes) {
    if (b < 0x80) {
      buf.writeCharCode(b);
    } else {
      buf.writeCharCode(_cp866Upper[b - 0x80]);
    }
  }
  return buf.toString();
}
