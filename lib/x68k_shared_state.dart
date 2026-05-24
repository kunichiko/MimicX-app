// ===================================================================================
// X68000 キーボード共有ステート
//
// X68000 から TARGET_RX で届く以下の状態を、Standard / LineInput など複数モード
// 間で共有する目的のコンテナ。これまで body / mode 個別に持っていたため、
// モード切替で LED 状態がリセットされてしまっていた。
//
// 持っている状態:
//   - LED 各キー (かな / ローマ字 / コード入力 / CAPS / INS / ひらがな / 全角)
//     の点灯状態
//   - LED 輝度 (0=最も明るい, 3=最も暗い)
//   - キーリピート開始遅延 / 間隔 (X68000 が SET REPEAT で配ってくる)
//   - 専用ディスプレイ制御 (TV リモコン) 関連:
//       * X68k/X1 モード (キー操作によるリモコン制御のモード切替)
//       * CTRL EN (本体発のディスプレイ制御コマンドを有効/無効化)
//       * OPT2 EN (OPT.2 + キーでもディスプレイ制御を発行可能にする)
//   - 専用ディスプレイ制御コマンド (one-shot) は onDisplayControl で通知
//
// X68kKeyboardPage の State が 1 つ生成し、TARGET_RX ハンドラを page 自身が
// 持って handleTargetRxByte に流す。各モードは constructor 経由でこのインスタンスを
// 受け取り、参照する。ChangeNotifier なので body 側は addListener で再描画フックを掛ける。
// ===================================================================================

import 'package:flutter/foundation.dart';

/// X68000 → キーボードの 1 バイト制御コマンドを受信した記録。
/// 受信ログ画面の表示に使う。
class TargetRxLogEntry {
  final DateTime timestamp;
  final int rawByte;
  final String interpretation;

  TargetRxLogEntry({
    required this.timestamp,
    required this.rawByte,
    required this.interpretation,
  });
}

/// 受信バイトを日本語の解釈文字列に変換する。
/// shared state でも log page でも使えるようトップレベル関数にしておく。
String interpretTargetRxByte(int byte) {
  if ((byte & 0x80) != 0) {
    // LED 状態 (bit7=1, 0=点灯, 1=消灯)
    const ledNames = ['かな', 'ローマ字', 'コード入力', 'CAPS', 'INS', 'ひらがな', '全角'];
    final lit = <String>[];
    for (int i = 0; i < 7; i++) {
      if (((byte >> i) & 1) == 0) lit.add(ledNames[i]);
    }
    return lit.isEmpty ? 'LED: (全消灯)' : 'LED: ${lit.join("+")}';
  }
  if ((byte & 0xC0) == 0x00) {
    return 'TV: ${DisplayControlCommand.label(byte & 0x3F)}';
  }
  if ((byte & 0xFC) == 0x48) {
    // 0b010010*X: KEY EN — キーボード→本体のキーコード送信許可。
    // bit=1 送信可 / bit=0 送信不可。TV Control 信号は影響を受けない。
    return (byte & 0x01) != 0
        ? 'KEY EN = 1 (送信可)'
        : 'KEY EN = 0 (送信不可)';
  }
  if ((byte & 0xFC) == 0x50) {
    return 'X68k/X1 mode = ${byte & 0x01}';
  }
  if ((byte & 0xFC) == 0x54) {
    return 'BRIGHT = ${byte & 0x03}';
  }
  if ((byte & 0xFC) == 0x58) {
    return 'CTRL EN = ${byte & 0x01}';
  }
  if ((byte & 0xFC) == 0x5C) {
    return 'OPT2 EN = ${byte & 0x01}';
  }
  if ((byte & 0xF0) == 0x60) {
    final n = byte & 0x0F;
    return 'REPEAT DELAY = $n (${200 + n * 100}ms)';
  }
  if ((byte & 0xF0) == 0x70) {
    final n = byte & 0x0F;
    return 'REPEAT INTERVAL = $n (${30 + n * n * 5}ms)';
  }
  return 'Unknown';
}

/// 専用ディスプレイ制御コマンド (X68000 → キーボード, 純正リモコンと同一コード)。
/// 0x01-0x1F が定義済み。0x20 以降は予約。
class DisplayControlCommand {
  static const int volUp = 0x01;
  static const int volDown = 0x02;
  static const int volNormal = 0x03;
  static const int chCall = 0x04;
  static const int reset = 0x05;
  static const int mute = 0x06;
  static const int powerOn = 0x07;
  static const int tvCom = 0x08;
  static const int video = 0x09;
  static const int contrastNormal = 0x0A;
  static const int chUp = 0x0B;
  static const int chDown = 0x0C;
  static const int powerOff = 0x0D;
  static const int powerToggle = 0x0E;
  static const int superToggle = 0x0F;
  static const int ch1 = 0x10;
  static const int ch2 = 0x11;
  static const int ch3 = 0x12;
  static const int ch4 = 0x13;
  static const int ch5 = 0x14;
  static const int ch6 = 0x15;
  static const int ch7 = 0x16;
  static const int ch8 = 0x17;
  static const int ch9 = 0x18;
  static const int ch10 = 0x19;
  static const int ch11 = 0x1A;
  static const int ch12 = 0x1B;
  static const int tv = 0x1C;
  static const int computer = 0x1D;
  static const int super1 = 0x1E;
  static const int super2 = 0x1F;

  /// 既知コードに日本語ラベルを返す。未知コードは "Unknown(0xXX)" を返す。
  static String label(int code) {
    switch (code) {
      case volUp: return 'ボリュームアップ';
      case volDown: return 'ボリュームダウン';
      case volNormal: return 'ボリュームノーマル';
      case chCall: return 'チャンネルコール';
      case reset: return 'テレビ画面リセット';
      case mute: return 'ミュート';
      case powerOn: return '電源 ON';
      case tvCom: return 'テレビ⇔コンピュータ';
      case video: return 'テレビ⇔外部入力';
      case contrastNormal: return 'コントラストノーマル';
      case chUp: return 'チャンネルアップ';
      case chDown: return 'チャンネルダウン';
      case powerOff: return '電源 OFF';
      case powerToggle: return '電源 ON/OFF';
      case superToggle: return 'スーパーインポーズ';
      case ch1: return 'チャンネル 1';
      case ch2: return 'チャンネル 2';
      case ch3: return 'チャンネル 3';
      case ch4: return 'チャンネル 4';
      case ch5: return 'チャンネル 5';
      case ch6: return 'チャンネル 6';
      case ch7: return 'チャンネル 7';
      case ch8: return 'チャンネル 8';
      case ch9: return 'チャンネル 9';
      case ch10: return 'チャンネル 10';
      case ch11: return 'チャンネル 11';
      case ch12: return 'チャンネル 12';
      case tv: return 'テレビ画面';
      case computer: return 'コンピュータ画面';
      case super1: return 'スーパーインポーズ (コントラストダウン)';
      case super2: return 'スーパーインポーズ (コントラストノーマル)';
      default: return 'Unknown(0x${code.toRadixString(16).padLeft(2, '0')})';
    }
  }
}

class X68kKeyboardSharedState extends ChangeNotifier {
  /// LED bit (0..6) → 対応 scancode
  static const List<int> ledBitToScancode = [
    0x5A, // bit0 かな
    0x5B, // bit1 ローマ字
    0x5C, // bit2 コード入力
    0x5D, // bit3 CAPS
    0x5E, // bit4 INS
    0x5F, // bit5 ひらがな
    0x60, // bit6 全角
  ];

  final Set<int> _ledOn = {};
  int _ledBrightness = 0;
  int _repeatDelayMs = 500;
  int _repeatIntervalMs = 110;

  // 専用ディスプレイ制御 (TV リモコン) 関連の状態フラグ。
  // いずれも X68000 起動時の初期値が不明なので「未受信 = null」「受信後にビット値を保持」とする。
  // 既知の bit 割り当て:
  //   - displayModeBit:   0b010100*X → X68k/X1 モード選択。極性未検証
  //   - displayCtrlEnBit: 0b010110*X → 本体発ディスプレイ制御の有効/無効。極性未検証
  //   - displayOpt2EnBit: 0b010111*X → OPT.2 + キーでの制御許可/禁止。
  //                                    実機観測で bit=0 が許可 (= inverted logic)
  int? _displayModeBit;
  int? _displayCtrlEnBit;
  int? _displayOpt2EnBit;

  Set<int> get ledOn => Set.unmodifiable(_ledOn);
  int get ledBrightness => _ledBrightness;
  int get repeatDelayMs => _repeatDelayMs;
  int get repeatIntervalMs => _repeatIntervalMs;

  int? get displayModeBit => _displayModeBit;
  int? get displayCtrlEnBit => _displayCtrlEnBit;
  int? get displayOpt2EnBit => _displayOpt2EnBit;

  // 受信ログ (newest last)。容量を超えたら先頭を捨てる。
  // ログ画面で「最新が上」表示する場合は表示側で reverse する。
  static const int _logCapacity = 100;
  final List<TargetRxLogEntry> _log = [];
  List<TargetRxLogEntry> get log => List.unmodifiable(_log);

  void clearLog() {
    if (_log.isEmpty) return;
    _log.clear();
    notifyListeners();
  }

  /// OPT.2 + キーで制御コマンドを発射してよいか。実機確認済み: bit=0 が許可。
  /// 未受信 (= null) は false 扱い。
  bool get displayOpt2Enabled => _displayOpt2EnBit == 0;

  bool isLedOn(int scancode) => _ledOn.contains(scancode);


  /// X68000 から届いた 1 バイトを解釈して state を更新する。
  /// 解釈不能なバイトは握りつぶす。ログ追加と notifyListeners は末尾で一括して行う。
  void handleTargetRxByte(int byte) {
    // まず受信ログに残す (解釈処理の有無にかかわらず全バイトを記録)。
    _log.add(TargetRxLogEntry(
      timestamp: DateTime.now(),
      rawByte: byte,
      interpretation: interpretTargetRxByte(byte),
    ));
    if (_log.length > _logCapacity) {
      _log.removeAt(0);
    }

    if ((byte & 0x80) != 0) {
      // LED 制御: bit7=1, bit6..0 が各 LED 状態 (0=点灯, 1=消灯)
      for (int i = 0; i < ledBitToScancode.length; i++) {
        final lit = ((byte >> i) & 1) == 0;
        final sc = ledBitToScancode[i];
        if (lit) {
          _ledOn.add(sc);
        } else {
          _ledOn.remove(sc);
        }
      }
    } else if ((byte & 0xC0) == 0x00) {
      // 0b00xxxxxx: 専用ディスプレイ制御コマンド (TV リモコン同等)。
      // 解釈はログ表示用 interpretTargetRxByte() に任せる。
    } else if ((byte & 0xF0) == 0x60) {
      // 0b0110dddd: キーリピート開始遅延 (200 + dddd × 100 ms)
      _repeatDelayMs = 200 + (byte & 0x0F) * 100;
    } else if ((byte & 0xF0) == 0x70) {
      // 0b0111rrrr: キーリピート間隔 (30 + rrrr² × 5 ms)
      final n = byte & 0x0F;
      _repeatIntervalMs = 30 + n * n * 5;
    } else if ((byte & 0xFC) == 0x54) {
      // 0b010101xx: LED 輝度 (xx=00 最も明るい, xx=11 最も暗い)
      _ledBrightness = byte & 0x03;
    } else if ((byte & 0xFC) == 0x50) {
      // 0b010100*X: ディスプレイ制御モード選択 (X68k / X1)。bit1 は don't care。
      _displayModeBit = byte & 0x01;
    } else if ((byte & 0xFC) == 0x58) {
      // 0b010110*X: CTRL EN — 本体発ディスプレイ制御の有効/無効。bit1 は don't care。
      _displayCtrlEnBit = byte & 0x01;
    } else if ((byte & 0xFC) == 0x5C) {
      // 0b010111*X: OPT2 EN — OPT.2 キーによるディスプレイ制御許可/禁止。bit1 は don't care。
      _displayOpt2EnBit = byte & 0x01;
    }
    // ログ更新と (どのパスでも) 状態変化を listeners に伝える。
    notifyListeners();
  }
}
