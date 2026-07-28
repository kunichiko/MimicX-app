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
import 'package:shared_preferences/shared_preferences.dart';

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
    return 'TV: ${DisplayControlCommand.labelOf(byte & 0x3F)}';
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

/// 仮想キーボード上のキー = (スキャンコード, 人間可読名) のペア。
/// `DisplayControlCommand` から参照される値オブジェクト。
class KeyBinding {
  /// X68000 スキャンコード (例: テンキー 1 = 0x4B)。
  final int scancode;

  /// キーの人間可読名 (例: "テンキー 1", "矢印 ↑")。
  final String keyName;

  const KeyBinding(this.scancode, this.keyName);
}

/// 専用ディスプレイ制御コマンド (X68000 → キーボード, 純正リモコンと同一コード)。
/// 0x01-0x1F が定義済み。0x20 以降は予約。
///
/// 1 コマンド = 1 インスタンスにまとめており、各エントリが
///   - `code`         : 純正リモコン互換のコード値 (0x01-0x1F)
///   - `label`        : 日本語ラベル (受信ログ・snackbar 用)
///   - `x68kBinding`  : X68000 モード時の仮想キーボードキー (SHIFT/OPT.2 + 押下で発射)
///   - `x1Binding`    : X1   モード時の仮想キーボードキー
///   - `repeatable`   : 押し続けで連続発射してよいか
/// を持つ。仮想キーボード側 (x68k_keyboard_page.dart) はここから
/// `byScancode(scancode, x1Mode: ...)` で引く形に統一しており、
/// コード値・ラベル・キーアサインを全てこの 1 箇所だけで管理できるようにしてある。
///
/// X68000 / X1 モードは本体が `0b010100*X` で配ってくる `displayModeBit` で決まる
/// (bit=1 → X68000, bit=0 → X1)。両モードで同じキーに割り当てる場合は両方に
/// 同じ KeyBinding を指定する。片方が null の場合、そのモードでは仮想キーボード
/// からは発射されない (本体経由でのみ届く)。
class DisplayControlCommand {
  /// リモコンコード (0x01-0x1F)。
  final int code;

  /// 日本語ラベル (受信ログや snackbar での表示用)。
  final String label;

  /// X68000 モード時のバインディング。null = X68000 モードでは仮想キーボード発射なし。
  final KeyBinding? x68kBinding;

  /// X1 モード時のバインディング。null = X1 モードでは仮想キーボード発射なし。
  final KeyBinding? x1Binding;

  /// REMOTE 端子からの連続発射間隔。null = 連続発射しない (1 回のみ)。
  /// 押下中、初回発射の後この間隔で REMOTE を再発射し続ける。
  /// 例: VOL_UP/DOWN は短め (snappy)、CH_UP/DOWN は実機準拠で 1 秒間隔。
  /// 一発系 (MUTE / CH 選局 等) は null。
  /// キーボード側の NoteOn 再送ペース (X68000 の SET REPEAT で可変) とは独立に
  /// 制御するため、固定 Duration で持つ。
  final Duration? remoteRepeatInterval;

  const DisplayControlCommand._({
    required this.code,
    required this.label,
    this.x68kBinding,
    this.x1Binding,
    this.remoteRepeatInterval,
  });

  /// 現在のモードに対応するバインディング (なければ null)。
  KeyBinding? bindingFor({required bool x1Mode}) =>
      x1Mode ? x1Binding : x68kBinding;

  // -------------------------------------------------------------------------
  // 仮想キーボード上のキー定義 (両モードで参照される共通カタログ)。
  // テンキー類は X68000 純正キーボードの並びに合わせている。
  // -------------------------------------------------------------------------
  static const _kArrowUp    = KeyBinding(0x3C, '矢印 ↑');
  static const _kArrowDown  = KeyBinding(0x3E, '矢印 ↓');
  static const _kArrowRight = KeyBinding(0x3D, '矢印 →');
  static const _kArrowLeft  = KeyBinding(0x3B, '矢印 ←');
  static const _kClr        = KeyBinding(0x3F, 'テンキー CLR');
  static const _kDiv        = KeyBinding(0x40, 'テンキー /');
  static const _kMul        = KeyBinding(0x41, 'テンキー *');
  static const _kMinus      = KeyBinding(0x42, 'テンキー -');
  static const _kPlus       = KeyBinding(0x46, 'テンキー +');
  static const _kEqual      = KeyBinding(0x4A, 'テンキー =');
  static const _kComma      = KeyBinding(0x50, 'テンキー ,');
  static const _kDot        = KeyBinding(0x51, 'テンキー .');
  static const _kNum0       = KeyBinding(0x4F, 'テンキー 0');
  static const _kNum1       = KeyBinding(0x4B, 'テンキー 1');
  static const _kNum2       = KeyBinding(0x4C, 'テンキー 2');
  static const _kNum3       = KeyBinding(0x4D, 'テンキー 3');
  static const _kNum4       = KeyBinding(0x47, 'テンキー 4');
  static const _kNum5       = KeyBinding(0x48, 'テンキー 5');
  static const _kNum6       = KeyBinding(0x49, 'テンキー 6');
  static const _kNum7       = KeyBinding(0x43, 'テンキー 7');
  static const _kNum8       = KeyBinding(0x44, 'テンキー 8');
  static const _kNum9       = KeyBinding(0x45, 'テンキー 9');

  // -------------------------------------------------------------------------
  // コマンド一覧 (code 昇順)。
  // 両モードで同じキーに割り当てるコマンドは x68kBinding/x1Binding 双方に同じ
  // KeyBinding を指定。モード固有 (テンキー . = + の 3 つ) は片方のみ指定。
  // -------------------------------------------------------------------------
  static const volUp = DisplayControlCommand._(
    code: 0x01,
    label: 'ボリュームアップ',
    x68kBinding: _kArrowUp, x1Binding: _kArrowUp,
    remoteRepeatInterval: Duration(milliseconds: 100),
  );
  static const volDown = DisplayControlCommand._(
    code: 0x02,
    label: 'ボリュームダウン',
    x68kBinding: _kArrowDown, x1Binding: _kArrowDown,
    remoteRepeatInterval: Duration(milliseconds: 100),
  );
  static const volNormal = DisplayControlCommand._(
    code: 0x03,
    label: 'ボリュームノーマル',
    x68kBinding: _kComma, x1Binding: _kComma,
  );
  static const chCall = DisplayControlCommand._(
    code: 0x04,
    label: 'チャンネルコール',
    x68kBinding: _kClr, x1Binding: _kClr,
  );
  static const reset = DisplayControlCommand._(
    code: 0x05,
    label: 'テレビ画面リセット',
  );
  static const mute = DisplayControlCommand._(
    code: 0x06,
    label: 'ミュート',
    x68kBinding: _kNum0, x1Binding: _kNum0,
  );
  static const ch16 = DisplayControlCommand._(
    code: 0x07,
    label: 'チャンネル 16',
    // 仮想キーボードへの割り当てなし。
  );
  // モード固有: X68000 モードの テンキー . はテレビ⇔コンピュータ切り替え。
  // X1 モードの テンキー . は computer (0x1D) を発射する。
  static const tvCom = DisplayControlCommand._(
    code: 0x08,
    label: 'テレビ⇔コンピュータ',
    x68kBinding: _kDot,
  );
  // モード固有: X68000 モードの テンキー = はテレビ⇔外部入力切り替え。
  // X1 モードの テンキー = は tv (0x1C) を発射する。
  static const video = DisplayControlCommand._(
    code: 0x09,
    label: 'テレビ⇔外部入力',
    x68kBinding: _kEqual,
  );
  static const contrastNormal = DisplayControlCommand._(
    code: 0x0A,
    label: 'コントラストノーマル',
  );
  static const chUp = DisplayControlCommand._(
    code: 0x0B,
    label: 'チャンネルアップ',
    x68kBinding: _kArrowRight, x1Binding: _kArrowRight,
    remoteRepeatInterval: Duration(seconds: 1),
  );
  static const chDown = DisplayControlCommand._(
    code: 0x0C,
    label: 'チャンネルダウン',
    x68kBinding: _kArrowLeft, x1Binding: _kArrowLeft,
    remoteRepeatInterval: Duration(seconds: 1),
  );
  // 0x0D は X68000 純正キーボードの SHIFT/OPT.2 + キーには割り当てが無い
  // (キーバインディング無し) が、SHARP リモコン本体には存在するコード。
  // ホスト側からは仮想 TV リモコン UI 経由でのみ発射される。
  static const subAudio = DisplayControlCommand._(
    code: 0x0D,
    label: '副音声',
  );
  static const powerToggle = DisplayControlCommand._(
    code: 0x0E,
    label: '電源 ON/OFF',
  );
  // モード固有: X68000 モードの テンキー + はスーパーインポーズ切り替え (0x0F)。
  // X1 モードの テンキー + は super1 (0x1E) を発射する。
  static const superToggle = DisplayControlCommand._(
    code: 0x0F,
    label: 'スーパーインポーズ',
    x68kBinding: _kPlus,
  );
  static const ch1 = DisplayControlCommand._(
    code: 0x10,
    label: 'チャンネル 1',
    x68kBinding: _kNum1, x1Binding: _kNum1,
  );
  static const ch2 = DisplayControlCommand._(
    code: 0x11,
    label: 'チャンネル 2',
    x68kBinding: _kNum2, x1Binding: _kNum2,
  );
  static const ch3 = DisplayControlCommand._(
    code: 0x12,
    label: 'チャンネル 3',
    x68kBinding: _kNum3, x1Binding: _kNum3,
  );
  static const ch4 = DisplayControlCommand._(
    code: 0x13,
    label: 'チャンネル 4',
    x68kBinding: _kNum4, x1Binding: _kNum4,
  );
  static const ch5 = DisplayControlCommand._(
    code: 0x14,
    label: 'チャンネル 5',
    x68kBinding: _kNum5, x1Binding: _kNum5,
  );
  static const ch6 = DisplayControlCommand._(
    code: 0x15,
    label: 'チャンネル 6',
    x68kBinding: _kNum6, x1Binding: _kNum6,
  );
  static const ch7 = DisplayControlCommand._(
    code: 0x16,
    label: 'チャンネル 7',
    x68kBinding: _kNum7, x1Binding: _kNum7,
  );
  static const ch8 = DisplayControlCommand._(
    code: 0x17,
    label: 'チャンネル 8',
    x68kBinding: _kNum8, x1Binding: _kNum8,
  );
  static const ch9 = DisplayControlCommand._(
    code: 0x18,
    label: 'チャンネル 9',
    x68kBinding: _kNum9, x1Binding: _kNum9,
  );
  static const ch10 = DisplayControlCommand._(
    code: 0x19,
    label: 'チャンネル 10',
    x68kBinding: _kDiv, x1Binding: _kDiv,
  );
  static const ch11 = DisplayControlCommand._(
    code: 0x1A,
    label: 'チャンネル 11',
    x68kBinding: _kMul, x1Binding: _kMul,
  );
  static const ch12 = DisplayControlCommand._(
    code: 0x1B,
    label: 'チャンネル 12',
    x68kBinding: _kMinus, x1Binding: _kMinus,
  );
  // モード固有: X1 モードでのみ仮想キーボードからの発射対象。
  static const tv = DisplayControlCommand._(
    code: 0x1C,
    label: 'テレビ画面',
    x1Binding: _kEqual,
  );
  static const computer = DisplayControlCommand._(
    code: 0x1D,
    label: 'コンピュータ画面',
    x1Binding: _kDot,
  );
  static const super1 = DisplayControlCommand._(
    code: 0x1E,
    label: 'スーパーインポーズ (コントラストダウン)',
    x1Binding: _kPlus,
  );
  static const super2 = DisplayControlCommand._(
    code: 0x1F,
    label: 'スーパーインポーズ (コントラストノーマル)',
  );

  /// 全コマンド (code 昇順)。`labelOf` / `byScancode` の探索元。
  static const List<DisplayControlCommand> all = [
    volUp, volDown, volNormal, chCall, reset, mute, ch16, tvCom, video,
    contrastNormal, chUp, chDown, subAudio, powerToggle, superToggle,
    ch1, ch2, ch3, ch4, ch5, ch6, ch7, ch8, ch9, ch10, ch11, ch12,
    tv, computer, super1, super2,
  ];

  /// 既知コードに日本語ラベルを返す。未知コードは "Unknown(0xXX)" を返す。
  static String labelOf(int code) {
    for (final c in all) {
      if (c.code == code) return c.label;
    }
    return 'Unknown(0x${code.toRadixString(16).padLeft(2, '0')})';
  }

  /// 仮想キーボードのスキャンコードから、現在モードに対応するコマンドを引く。
  /// 該当キーに割り当てが無い場合は null。
  static DisplayControlCommand? byScancode(int scancode, {required bool x1Mode}) {
    for (final c in all) {
      final b = x1Mode ? c.x1Binding : c.x68kBinding;
      if (b != null && b.scancode == scancode) return c;
    }
    return null;
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

  /// アダプタ個体シリアル (Chip UID 由来 16 桁 hex)。
  /// X68000 はキーリピート設定 (SET REPEAT DELAY / RATE) を起動時にしか送らない
  /// ため、X68k 起動後に MimicX を接続すると初期値 (500ms / 110ms) のままになる。
  /// 個体ごとに「最後に X68k から受信した値」を SharedPreferences に保存し、
  /// 次回起動時はそれをデフォルトに上書きすることでこの取りこぼしを救う。
  /// null/空なら永続化しない (in-memory only)。
  final String? serial;

  X68kKeyboardSharedState({this.serial}) {
    _loadPersistedRepeatSettings();
  }

  final Set<int> _ledOn = {};
  int _ledBrightness = 0;
  // キーリピート設定の初期値はファーム / プロトコル仕様の保守的なデフォルト。
  // serial が分かっていて永続化済みの値があれば _loadPersistedRepeatSettings が
  // 起動直後に上書きする。
  int _repeatDelayMs = 500;
  int _repeatIntervalMs = 110;

  // 専用ディスプレイ制御 (TV リモコン) 関連の状態フラグ。
  // いずれも X68000 起動時の初期値が不明なので「未受信 = null」「受信後にビット値を保持」とする。
  // 既知の bit 割り当て:
  //   - displayModeBit:   0b010100*X → X68k/X1 モード選択。
  //                                    実機観測で bit=1 が X68000, bit=0 が X1
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

  /// 現在のディスプレイ制御モードが X1 互換モードか。
  /// 実機観測で `displayModeBit` は bit=1 が X68000, bit=0 が X1。
  /// 未受信 (null) のときは X68000 既定 (= false) として扱う。
  bool get isX1Mode => _displayModeBit == 0;

  bool isLedOn(int scancode) => _ledOn.contains(scancode);

  // ---------------------------------------------------------------------------
  // キーリピート設定のシリアル別永続化
  // ---------------------------------------------------------------------------
  // SharedPreferences キー (serial が無い場合は null を返して no-op にする)。
  String? get _kRepeatDelay => (serial != null && serial!.isNotEmpty)
      ? 'x68k_keyboard.$serial.repeatDelayMs'
      : null;
  String? get _kRepeatInterval => (serial != null && serial!.isNotEmpty)
      ? 'x68k_keyboard.$serial.repeatIntervalMs'
      : null;

  Future<void> _loadPersistedRepeatSettings() async {
    final dKey = _kRepeatDelay;
    final iKey = _kRepeatInterval;
    if (dKey == null || iKey == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final d = prefs.getInt(dKey);
      final i = prefs.getInt(iKey);
      bool changed = false;
      if (d != null && d != _repeatDelayMs) {
        _repeatDelayMs = d;
        changed = true;
      }
      if (i != null && i != _repeatIntervalMs) {
        _repeatIntervalMs = i;
        changed = true;
      }
      if (changed) notifyListeners();
    } catch (_) {
      // 読み込み失敗は初期値のまま続行
    }
  }

  Future<void> _persistRepeatSettings() async {
    final dKey = _kRepeatDelay;
    final iKey = _kRepeatInterval;
    if (dKey == null || iKey == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(dKey, _repeatDelayMs);
      await prefs.setInt(iKey, _repeatIntervalMs);
    } catch (_) {
      // 保存失敗は無視 (致命的ではない)
    }
  }


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
      // serial が分かっていれば次回起動時のために値を保存。
      // fire-and-forget で十分 (失敗しても致命的ではない)。
      _persistRepeatSettings();
    } else if ((byte & 0xF0) == 0x70) {
      // 0b0111rrrr: キーリピート間隔 (30 + rrrr² × 5 ms)
      final n = byte & 0x0F;
      _repeatIntervalMs = 30 + n * n * 5;
      _persistRepeatSettings();
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
