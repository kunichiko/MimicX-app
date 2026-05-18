#include "flutter_window.h"

#include <imm.h>

#include <optional>
#include <variant>

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

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
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // "mimicx/windows_ime" メソッドチャネル:
  //   setEnabled(false) → Flutter view HWND の IME コンテキストを外し、
  //   OS IME (Microsoft IME の「あ」モード等) にキーを横取りされないようにする。
  //   setEnabled(true)  → 既定の IME コンテキストを再アタッチする。
  // 標準キーボード / ジョイスティック等は false、ライン入力 (漢字) モードのみ
  // true を呼ぶ運用。
  ime_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(),
          "mimicx/windows_ime",
          &flutter::StandardMethodCodec::GetInstance());
  ime_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setEnabled") {
          result->NotImplemented();
          return;
        }
        bool enabled = false;
        if (const auto* args =
                std::get_if<flutter::EncodableMap>(call.arguments())) {
          const auto it = args->find(flutter::EncodableValue("enabled"));
          if (it != args->end()) {
            if (const auto* b = std::get_if<bool>(&it->second)) {
              enabled = *b;
            }
          }
        }
        HWND view_hwnd =
            flutter_controller_
                ? flutter_controller_->view()->GetNativeWindow()
                : nullptr;
        if (view_hwnd == nullptr) {
          result->Error("no_view", "Flutter view HWND not available");
          return;
        }
        // ImmAssociateContextEx(hwnd, NULL, IACE_DEFAULT) でスレッド既定の
        // IME コンテキストを再アタッチ。ImmAssociateContext(hwnd, NULL) で
        // このウィンドウから IME を完全に切り離す。
        if (enabled) {
          ::ImmAssociateContextEx(view_hwnd, nullptr, IACE_DEFAULT);
        } else {
          ::ImmAssociateContext(view_hwnd, nullptr);
        }
        result->Success();
      });

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
  // engine が消える前にチャネルを破棄しておく。コールバック中に
  // flutter_controller_ が解放されるレースを防ぐため。
  if (ime_channel_) {
    ime_channel_->SetMethodCallHandler(nullptr);
    ime_channel_ = nullptr;
  }
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
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
