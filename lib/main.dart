// ─────────────────────────────────────────────
// Точка входа Wi-Fi Monitor (Windows).
//
// Поведение 1:1 с Python main.py / ui/window.py:
//   1. Инициализируем window_manager (фикс. размер 600×400, заголовок,
//      центрирование) и tray_manager (иконка tray_red.png).
//   2. Загружаем сохранённые учётные данные. Если их нет/неполные —
//      показываем модальный диалог запроса (даже при автозапуске:
//      окно показывается поверх, без него мониторить нечего).
//   3. Загружаем Prefs (интервалы + router_ip).
//   4. Создаём TrayController (Открыть / Выход / иконка).
//   5. Поднимаем MainWindow. Если процесс запущен с --autostart —
//      главное окно не показываем сразу; пользователь откроет его
//      через двойной клик / пункт меню трея.
//
// Закрытие крестиком → preventClose → окно прячется в трей.
// Выход возможен только из меню трея (TrayController.onQuit → exit(0)).
// ─────────────────────────────────────────────

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:window_manager/window_manager.dart';

import 'core/constants.dart';
import 'core/models.dart';
import 'core/settings_service.dart';
import 'ui/credentials_dialog.dart';
import 'ui/main_window.dart';
import 'ui/styles.dart';
import 'ui/tray_controller.dart';

/// Признак запуска через автозапуск. Команда в HKCU\...\Run
/// теперь явно добавляет [kAutostartArgument] (см. AutostartService),
/// но продолжаем понимать два альтернативных старых варианта на
/// случай, если кто-то поправил реестр вручную.
bool _isAutostart(List<String> args) {
  const accepted = <String>{
    kAutostartArgument,
    '-autostart',
    '/autostart',
  };
  for (final a in args) {
    if (accepted.contains(a.trim().toLowerCase())) return true;
  }
  return false;
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final autostart = _isAutostart(args);

  // ── 1. Окно ────────────────────────────────
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(kAppWidth, kAppHeight),
    minimumSize: Size(kAppWidth, kAppHeight),
    maximumSize: Size(kAppWidth, kAppHeight),
    center: true,
    title: kAppTitle,
    titleBarStyle: TitleBarStyle.normal,
    skipTaskbar: false,
  );

  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.setTitle(kAppTitle);
    await windowManager.setSize(const Size(kAppWidth, kAppHeight));
    await windowManager.setMinimumSize(const Size(kAppWidth, kAppHeight));
    await windowManager.setMaximumSize(const Size(kAppWidth, kAppHeight));
    await windowManager.setResizable(false);
    await windowManager.setMaximizable(false);
    await windowManager.center();
    // При обычном запуске показываем окно. При автозапуске — оставляем
    // скрытым (пользователь откроет через трей), как в Python.
    if (autostart) {
      await windowManager.hide();
      await windowManager.setSkipTaskbar(true);
    } else {
      await windowManager.show();
      await windowManager.focus();
    }
  });

  // ── 2. Сервисы ─────────────────────────────
  final settings = SettingsService();
  final creds = await settings.loadCredentials();

  // ── 3. Запускаем UI ────────────────────────
  // Сначала поднимаем приложение, чтобы был BuildContext для диалога
  // запроса кредов. Если creds нет — MainWindow стартует уже с креды.
  runApp(
    _Bootstrap(
      autostart: autostart,
      settings: settings,
      initialCreds: creds,
    ),
  );
}

/// Корневой виджет приложения. ВАЖНО: внутри `MaterialApp.home` сидит
/// _BootRoot, который и занимается загрузкой/диалогом/трей. Так у диалога
/// есть валидный BuildContext с MaterialLocalizations (иначе Flutter падает
/// с "No MaterialLocalizations found").
class _Bootstrap extends StatelessWidget {
  final bool autostart;
  final SettingsService settings;
  final Credentials initialCreds;

  const _Bootstrap({
    required this.autostart,
    required this.settings,
    required this.initialCreds,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: kAppTitle,
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      // Локализации обязательны для Material/Cupertino-виджетов и для
      // showDialog. Явно указываем русскую локаль, чтобы стандартные
      // тексты (например, "Скрыть"/"Показать" в TextField) были на русском.
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: _BootRoot(
        autostart: autostart,
        settings: settings,
        initialCreds: initialCreds,
      ),
    );
  }
}

/// Загрузочный экран: если креды отсутствуют — показывает диалог,
/// затем загружает Prefs и подменяет себя на MainWindow.
///
/// Живёт ВНУТРИ MaterialApp.home, поэтому BuildContext уже содержит
/// MaterialLocalizations / Navigator / Overlay — всё, что нужно showDialog.
class _BootRoot extends StatefulWidget {
  final bool autostart;
  final SettingsService settings;
  final Credentials initialCreds;

  const _BootRoot({
    required this.autostart,
    required this.settings,
    required this.initialCreds,
  });

  @override
  State<_BootRoot> createState() => _BootRootState();
}

class _BootRootState extends State<_BootRoot> {
  Credentials? _creds;
  Prefs? _prefs;
  TrayController? _tray;
  bool _starting = true;
  String? _fatalError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _boot());
  }

  Future<void> _boot() async {
    try {
      // 1) Креды. Если remember=true и пароль есть — используем как есть.
      //    Иначе всегда показываем диалог (даже при автостарте: без кред
      //    мониторить нечего).
      var creds = widget.initialCreds;
      if (!creds.isFilled) {
        // Если был автозапуск — нужно сначала показать окно, иначе
        // диалог окажется "невидимым".
        if (widget.autostart) {
          await windowManager.show();
          await windowManager.focus();
          await windowManager.setSkipTaskbar(false);
        }
        if (!mounted) return;
        final entered =
            await showCredentialsDialog(context, widget.settings);
        if (entered == null || !entered.isFilled) {
          // Отмена / пусто — выход.
          await _quit();
          return;
        }
        creds = entered;
      }

      // 2) Prefs.
      final prefs = await widget.settings.loadPrefs();

      // 3) Трей.
      final tray = TrayController(
        onOpen: _showMainWindow,
        onQuit: _quit,
      );
      await tray.init();

      if (!mounted) return;
      setState(() {
        _creds = creds;
        _prefs = prefs;
        _tray = tray;
        _starting = false;
      });
    } catch (e, st) {
      debugPrint('Bootstrap failed: $e\n$st');
      if (!mounted) return;
      setState(() {
        _starting = false;
        _fatalError = e.toString();
      });
    }
  }

  Future<void> _showMainWindow() async {
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    try {
      await _tray?.dispose();
    } catch (_) {/* ignore */}
    try {
      await windowManager.destroy();
    } catch (_) {/* ignore */}
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    if (_fatalError != null) {
      return _FatalErrorScreen(message: _fatalError!, onExit: _quit);
    }
    if (_starting || _creds == null || _prefs == null || _tray == null) {
      // Пустой Scaffold, чтобы окно было "живым" пока поднимается диалог.
      return const Scaffold(
        backgroundColor: Colors.white,
        body: SizedBox.shrink(),
      );
    }
    return MainWindow(
      credentials: _creds!,
      initialPrefs: _prefs!,
      settings: widget.settings,
      tray: _tray!,
      onQuit: _quit,
    );
  }

  @override
  void dispose() {
    // Слушателя трея снимает сам TrayController.dispose(); здесь ничего
    // делать не нужно — в прошлой версии тут был неверный cast, который
    // ничего полезного не делал.
    super.dispose();
  }
}

class _FatalErrorScreen extends StatelessWidget {
  final String message;
  final Future<void> Function() onExit;
  const _FatalErrorScreen({required this.message, required this.onExit});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Не удалось запустить Wi-Fi Монитор',
              style: kTitleStyle,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(
              message,
              style: kInfoStyle,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              style: kButtonStop,
              onPressed: onExit,
              child: const Text('Выход'),
            ),
          ],
        ),
      ),
    );
  }
}
