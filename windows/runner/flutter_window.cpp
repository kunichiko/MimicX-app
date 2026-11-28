#include "flutter_window.h"

#include <commctrl.h>
#include <imm.h>

#include <optional>
#include <variant>

#include <flutter/event_stream_handler_functions.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {
// IME 状態のポーリング用タイマー ID (トップレベルウィンドウに設定)。
// WM_IME_NOTIFY を送ってこない IME への保険。
constexpr UINT_PTR kImePollTimerId = 0x4D49;  // 'MI'
constexpr UINT kImePollIntervalMs = 250;
constexpr UINT_PTR kViewSubclassId = 1;
}  // namespace

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
        // 有効/無効で IME の見え方 (オン/オフ) が変わるので通知し直す。
        EmitImeState(true);
      });

  // "mimicx/input_source" イベントチャネル:
  //   {japanese: bool, open: bool, conversion: int} を流す。japanese は
  //   「IME がオン」のとき true (変換モードは見ない。EmitImeState 参照)。
  //   標準キーボード画面では IME を有効 (オフ状態) にしておき、ユーザーが
  //   半角/全角等で IME をオンにしたら Dart 側が入力バーを出す。
  view_hwnd_ = flutter_controller_->view()->GetNativeWindow();
  input_source_channel_ =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "mimicx/input_source",
          &flutter::StandardMethodCodec::GetInstance());
  input_source_channel_->SetStreamHandler(
      std::make_unique<
          flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [this](const flutter::EncodableValue* arguments,
                 std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                     events)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            input_source_sink_ = std::move(events);
            EmitImeState(true);
            return nullptr;
          },
          [this](const flutter::EncodableValue* arguments)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            input_source_sink_ = nullptr;
            return nullptr;
          }));
  // IME のオン/オフ通知 (WM_IME_NOTIFY) はフォーカスを持つ Flutter view
  // (子ウィンドウ) に届くので、サブクラス化して拾う。
  ::SetWindowSubclass(view_hwnd_, ViewSubclassProc, kViewSubclassId,
                      reinterpret_cast<DWORD_PTR>(this));
  ::SetTimer(GetHandle(), kImePollTimerId, kImePollIntervalMs, nullptr);

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::EmitImeState(bool force) {
  if (!input_source_sink_ || view_hwnd_ == nullptr) return;
  bool open = false;
  DWORD conversion = 0;
  DWORD sentence = 0;
  // IME を切り離している (標準キーボード以外の画面) ときは NULL が返る。
  HIMC himc = ::ImmGetContext(view_hwnd_);
  if (himc != nullptr) {
    open = ::ImmGetOpenStatus(himc) != FALSE;
    ::ImmGetConversionStatus(himc, &conversion, &sentence);
    ::ImmReleaseContext(view_hwnd_, himc);
  }
  // 変換モード (ひらがな / 英数) は見ず、IME がオンかどうかだけで判定する。
  // MS-IME は Shift+英字の間だけ変換モードを全角英数 (NATIVE ビットなし) に
  // 一時的に切り替えるため、モードで判定するとその瞬間に入力バーが消えて
  // フォーカスが外れ、変換中の文字が確定・送信されて IME と食い違う。
  // IME がオンなら英数モードでもキーは IME が受け取るので、バーは出しておく。
  const bool japanese = open;
  const int state = japanese ? 1 : 0;
  if (!force && state == last_ime_japanese_) return;
  last_ime_japanese_ = state;
  flutter::EncodableMap event{
      {flutter::EncodableValue("japanese"), flutter::EncodableValue(japanese)},
      {flutter::EncodableValue("open"), flutter::EncodableValue(open)},
      {flutter::EncodableValue("conversion"),
       flutter::EncodableValue(static_cast<int32_t>(conversion))},
      {flutter::EncodableValue("id"), flutter::EncodableValue("windows-imm")},
  };
  input_source_sink_->Success(flutter::EncodableValue(event));
}

LRESULT CALLBACK FlutterWindow::ViewSubclassProc(HWND hwnd, UINT message,
                                                 WPARAM wparam, LPARAM lparam,
                                                 UINT_PTR subclass_id,
                                                 DWORD_PTR ref_data) {
  auto* self = reinterpret_cast<FlutterWindow*>(ref_data);
  const LRESULT result = ::DefSubclassProc(hwnd, message, wparam, lparam);
  switch (message) {
    case WM_IME_NOTIFY:
      if (wparam == IMN_SETOPENSTATUS || wparam == IMN_SETCONVERSIONMODE) {
        self->EmitImeState(false);
      }
      break;
    case WM_SETFOCUS:
      self->EmitImeState(false);
      break;
  }
  return result;
}

void FlutterWindow::OnDestroy() {
  ::KillTimer(GetHandle(), kImePollTimerId);
  if (view_hwnd_ != nullptr) {
    ::RemoveWindowSubclass(view_hwnd_, ViewSubclassProc, kViewSubclassId);
    view_hwnd_ = nullptr;
  }
  if (input_source_channel_) {
    input_source_channel_->SetStreamHandler(nullptr);
    input_source_channel_ = nullptr;
  }
  input_source_sink_ = nullptr;

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
    case WM_TIMER:
      if (wparam == kImePollTimerId) {
        EmitImeState(false);
        return 0;
      }
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
