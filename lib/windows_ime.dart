// Windows のキーボード IME (ImmAssociateContext) をモード毎に有効/無効化する
// ためのプラットフォームチャネル。
//
// 標準キーボード・ジョイスティック等の物理キー入力モードでは IME を無効化し、
// ライン入力モード (TextField で日本語入力したい) だけ IME を有効化する。
// Windows 以外のプラットフォームでは何もしない (no-op)。

import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class WindowsIme {
  WindowsIme._();

  static const MethodChannel _channel = MethodChannel('mimicx/windows_ime');

  static Future<void> setEnabled(bool enabled) async {
    if (kIsWeb || !Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>(
        'setEnabled',
        <String, dynamic>{'enabled': enabled},
      );
    } catch (e) {
      debugPrint('WindowsIme.setEnabled($enabled) failed: $e');
    }
  }
}
