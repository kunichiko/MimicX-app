#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/event_channel.h>
#include <flutter/method_channel.h>

#include <memory>

#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // "mimicx/windows_ime" メソッドチャネル。Dart 側から Flutter view HWND の
  // IME を ON/OFF できるようにする。実体は OnCreate() を参照。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      ime_channel_;

  // "mimicx/input_source" イベントチャネル。日本語 IME のオン/オフを Dart
  // (lib/ime_state.dart) に流す。標準キーボード画面で IME がオンのときだけ
  // 入力バーを出すため。
  std::unique_ptr<flutter::EventChannel<flutter::EncodableValue>>
      input_source_channel_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>
      input_source_sink_;
  // 前回流した状態 (変化したときだけ流す)。-1 = 未送信。
  int last_ime_japanese_ = -1;

  // Flutter view の HWND (IME の通知はフォーカスを持つ子ウィンドウに届く)。
  HWND view_hwnd_ = nullptr;

  // 現在の IME 状態を調べ、変化していれば (force なら常に) Dart へ流す。
  void EmitImeState(bool force);

  // Flutter view をサブクラス化して WM_IME_NOTIFY を拾う。
  static LRESULT CALLBACK ViewSubclassProc(HWND hwnd, UINT message,
                                           WPARAM wparam, LPARAM lparam,
                                           UINT_PTR subclass_id,
                                           DWORD_PTR ref_data);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
