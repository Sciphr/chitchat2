#include "flutter_window.h"

#include <flutter/encodable_value.h>

#include <optional>
#include <shellapi.h>

#include "flutter/generated_plugin_registrant.h"
#include "resource.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  native_window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "chitchat2/native_window",
          &flutter::StandardMethodCodec::GetInstance());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
  taskbar_created_message_ = RegisterWindowMessage(L"TaskbarCreated");

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  RemoveTrayIcon();
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_CLOSE:
      if (!allow_window_close_) {
        if (HideToTray()) {
          return 0;
        }
      }
      break;
    case WM_QUERYENDSESSION:
    case WM_ENDSESSION:
      allow_window_close_ = true;
      break;
    case WM_COMMAND:
      switch (LOWORD(wparam)) {
        case IDM_TRAY_OPEN:
          RestoreFromTray();
          return 0;
        case IDM_TRAY_EXIT:
          ExitApplication();
          return 0;
      }
      break;
    case kTrayIconMessage:
      switch (lparam) {
        case WM_LBUTTONUP:
        case WM_LBUTTONDBLCLK:
          RestoreFromTray();
          return 0;
        case WM_RBUTTONUP:
        case WM_CONTEXTMENU: {
          POINT cursor_position;
          GetCursorPos(&cursor_position);
          ShowTrayContextMenu(cursor_position);
          return 0;
        }
      }
      break;
    case WM_COPYDATA: {
      auto* copy_data = reinterpret_cast<COPYDATASTRUCT*>(lparam);
      if (copy_data != nullptr &&
          copy_data->dwData == FlutterWindow::kDeepLinkCopyDataId &&
          copy_data->lpData != nullptr) {
        RestoreFromTray();
        ForwardDeepLink(static_cast<const char*>(copy_data->lpData));
        return 0;
      }
      break;
    }
  }

  if (taskbar_created_message_ != 0 && message == taskbar_created_message_ &&
      tray_icon_visible_) {
    AddTrayIcon();
    return 0;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}

void FlutterWindow::ForwardDeepLink(const std::string& deep_link) {
  if (!native_window_channel_ || deep_link.empty()) {
    return;
  }

  native_window_channel_->InvokeMethod(
      "handleDeepLink",
      std::make_unique<flutter::EncodableValue>(deep_link));
}

void FlutterWindow::RestoreFromTray() {
  RemoveTrayIcon();
  ShowWindow(GetHandle(), SW_SHOWNORMAL);
  SetForegroundWindow(GetHandle());
}

bool FlutterWindow::HideToTray() {
  if (!AddTrayIcon()) {
    return false;
  }
  ShowWindow(GetHandle(), SW_HIDE);
  return true;
}

void FlutterWindow::ExitApplication() {
  allow_window_close_ = true;
  RemoveTrayIcon();
  DestroyWindow(GetHandle());
}

void FlutterWindow::ShowTrayContextMenu(POINT cursor_position) {
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    return;
  }

  AppendMenu(menu, MF_STRING, IDM_TRAY_OPEN, L"Open ChitChat");
  AppendMenu(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenu(menu, MF_STRING, IDM_TRAY_EXIT, L"Exit");

  SetForegroundWindow(GetHandle());
  TrackPopupMenu(menu, TPM_BOTTOMALIGN | TPM_LEFTALIGN | TPM_RIGHTBUTTON,
                 cursor_position.x, cursor_position.y, 0, GetHandle(), nullptr);
  PostMessage(GetHandle(), WM_NULL, 0, 0);
  DestroyMenu(menu);
}

bool FlutterWindow::AddTrayIcon() {
  NOTIFYICONDATA icon_data{};
  icon_data.cbSize = sizeof(NOTIFYICONDATA);
  icon_data.hWnd = GetHandle();
  icon_data.uID = IDI_APP_ICON;
  icon_data.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
  icon_data.uCallbackMessage = kTrayIconMessage;
  icon_data.hIcon = static_cast<HICON>(LoadImage(
      GetModuleHandle(nullptr), MAKEINTRESOURCE(IDI_APP_ICON), IMAGE_ICON,
      GetSystemMetrics(SM_CXSMICON), GetSystemMetrics(SM_CYSMICON), 0));
  wcscpy_s(icon_data.szTip, L"ChitChat");

  const DWORD action = tray_icon_visible_ ? NIM_MODIFY : NIM_ADD;
  const bool success = Shell_NotifyIcon(action, &icon_data) == TRUE;
  if (icon_data.hIcon != nullptr) {
    DestroyIcon(icon_data.hIcon);
  }
  tray_icon_visible_ = success;
  return success;
}

void FlutterWindow::RemoveTrayIcon() {
  if (!tray_icon_visible_) {
    return;
  }

  NOTIFYICONDATA icon_data{};
  icon_data.cbSize = sizeof(NOTIFYICONDATA);
  icon_data.hWnd = GetHandle();
  icon_data.uID = IDI_APP_ICON;
  Shell_NotifyIcon(NIM_DELETE, &icon_data);
  tray_icon_visible_ = false;
}
