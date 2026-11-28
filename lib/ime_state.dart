// OS の日本語入力 (IM) がオンかどうかを監視する。
//
// 標準キーボード画面では物理キーをそのままスキャンコードで X68000 に送るが、
// 日本語 IM がオンになったときだけキーボードの上に入力バー (ImeLineBar) を出し、
// 変換を確定した文字列をコード入力で送る。その切り替えのための状態。
//
// - macOS: ネイティブ側 (MainFlutterWindow.swift) が入力ソースの変更通知
//   (kTISNotifySelectedKeyboardInputSourceChanged) を受けて EventChannel で流す。
//   「日本語の入力ソースで、かつ英字 (Roman) モードでない」ときに on。
// - それ以外のプラットフォーム: 未対応 (常に off)。

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class ImeState {
  ImeState._();

  static const EventChannel _channel = EventChannel('mimicx/input_source');

  /// 日本語 IM がオン (かな入力中) か。
  static final ValueNotifier<bool> japaneseOn = ValueNotifier(false);

  static StreamSubscription<dynamic>? _sub;

  static bool get supported => !kIsWeb && Platform.isMacOS;

  /// 監視を開始する (何度呼んでもよい)。
  static void ensureStarted() {
    if (!supported || _sub != null) return;
    _sub = _channel.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        final on = event['japanese'] == true;
        debugPrint('[IME] input source: id=${event['id']} mode=${event['mode']}'
            ' languages=${event['languages']} → japanese=$on');
        japaneseOn.value = on;
      },
      onError: (Object e) {
        debugPrint('[IME] input source monitor error: $e');
      },
    );
  }
}
