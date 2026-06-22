#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Стартовый размер совпадает с фиксированным размером окна в Dart
  // (kAppWidth/kAppHeight в lib/ui/styles.dart). window_manager поправит
  // позицию (центрирование) и видимость уже из Dart.
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(600, 400);
  if (!window.Create(L"Wi-Fi \u041C\u043E\u043D\u0438\u0442\u043E\u0440", origin, size)) {
    return EXIT_FAILURE;
  }
  // Не выходим из приложения при закрытии главного окна —
  // главное окно может быть скрыто в трей (preventClose в Dart).
  // Реальный выход выполняется через TrayController -> exit(0).
  window.SetQuitOnClose(false);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
