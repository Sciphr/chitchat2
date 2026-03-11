#include <bitsdojo_window_windows/bitsdojo_window_plugin.h>
#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <optional>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kSingleInstanceMutexName[] = L"Local\\ChitChat2SingleInstance";

std::optional<std::string> FindProtocolActivationUri(
    const std::vector<std::string>& command_line_arguments) {
  for (const auto& argument : command_line_arguments) {
    if (argument.rfind("chitchat2://", 0) == 0) {
      return argument;
    }
  }
  return std::nullopt;
}

void FocusWindow(HWND window) {
  if (IsIconic(window)) {
    ShowWindow(window, SW_RESTORE);
  } else {
    ShowWindow(window, SW_SHOW);
  }
  SetForegroundWindow(window);
}

bool ActivateExistingInstance(
    const std::optional<std::string>& activation_uri) {
  HWND existing_window =
      FindWindow(Win32Window::kWindowClassName, nullptr);
  if (existing_window == nullptr) {
    return false;
  }

  FocusWindow(existing_window);

  if (activation_uri.has_value()) {
    COPYDATASTRUCT payload{};
    payload.dwData = FlutterWindow::kDeepLinkCopyDataId;
    payload.cbData = static_cast<DWORD>(activation_uri->size() + 1);
    payload.lpData = const_cast<char*>(activation_uri->c_str());

    DWORD_PTR result = 0;
    SendMessageTimeout(existing_window, WM_COPYDATA, 0,
                       reinterpret_cast<LPARAM>(&payload), SMTO_ABORTIFHUNG,
                       5000, &result);
  }

  return true;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  const std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();
  HANDLE single_instance_mutex =
      CreateMutex(nullptr, TRUE, kSingleInstanceMutexName);
  if (single_instance_mutex != nullptr &&
      GetLastError() == ERROR_ALREADY_EXISTS) {
    ActivateExistingInstance(
        FindProtocolActivationUri(command_line_arguments));
    CloseHandle(single_instance_mutex);
    return EXIT_SUCCESS;
  }

  static_cast<void>(
      bitsdojo_window_configure(BDW_CUSTOM_FRAME | BDW_HIDE_ON_STARTUP));

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");
  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"chitchat2", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance_mutex != nullptr) {
    CloseHandle(single_instance_mutex);
  }
  return EXIT_SUCCESS;
}
