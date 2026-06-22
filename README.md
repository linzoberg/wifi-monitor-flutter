# Wi-Fi Монитор (Flutter / Windows)

Порт desktop-приложения **Wi-Fi Monitor v0.3.5** с Python (PyQt5) на **Flutter для Windows**.
Функциональность и интерфейс полностью повторяют оригинал.

## Возможности

- Мониторинг подключения к выбранной Wi-Fi сети через `netsh wlan`
- Автоматическое переподключение при разрыве (пересоздание WLAN-профиля)
- Пинг 8.8.8.8 каждые N секунд с цветовой индикацией задержки
- Детектирование VPN (задержка `< 1` мс)
- Системный трей с цветной иконкой (🟢 подключено / 🔴 нет связи)
- Сворачивание в трей при закрытии окна
- Сохранение SSID + шифрованного пароля (Windows Credential Manager / DPAPI)
- Настройки интервалов проверки и пинга
- Автозапуск через `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`

## Требования

1. **Flutter SDK** 3.19+ — [flutter.dev/docs/get-started/install/windows](https://docs.flutter.dev/get-started/install/windows)
2. Включена поддержка Windows desktop:
   ```powershell
   flutter config --enable-windows-desktop
   ```
3. **Visual Studio 2022** с компонентом *"Desktop development with C++"*
   (нужен MSVC v143 + Windows 10/11 SDK)
4. **Android Studio** с плагинами **Flutter** и **Dart**

## Запуск из Android Studio

1. `File` → `Open` → выбрать папку `wifi-monitor-flutter`
2. Дождаться `flutter pub get` (или запустить вручную в терминале)
3. В правом верхнем углу выбрать устройство **Windows (desktop)**
4. Нажать **Run** ▶

## Запуск из командной строки

```powershell
cd wifi-monitor-flutter
flutter pub get
flutter run -d windows
```

## Сборка релизного `.exe`

```powershell
flutter build windows --release
```

Готовый исполняемый файл и его зависимости появятся в:
```
build\windows\x64\runner\Release\
```

## Структура проекта

```
lib/
├── main.dart                       # точка входа
├── core/
│   ├── constants.dart              # ROUTER_IP, интервалы, попытки
│   ├── models.dart                 # Prefs, Credentials, MonitorStatus, PingResult
│   ├── process_runner.dart         # запуск netsh/ping со скрытым окном
│   ├── wifi_monitor.dart           # netsh wlan: scan / connect / check
│   ├── ping_service.dart           # пинг 8.8.8.8 + детект VPN
│   ├── monitor_service.dart        # основной цикл мониторинга
│   ├── settings_service.dart       # JSON-настройки + secure storage
│   └── autostart_service.dart      # HKCU\...\Run
└── ui/
    ├── styles.dart                 # цвета, размеры, ThemeData
    ├── credentials_dialog.dart     # стартовый диалог SSID/пароль
    ├── prefs_dialog.dart           # диалог настроек
    ├── tray_controller.dart        # обёртка над tray_manager
    └── main_window.dart            # главное окно
```

## Лицензия

Тот же набор условий, что и у оригинального Python-приложения.
