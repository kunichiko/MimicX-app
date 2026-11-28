// 文字列を X68000 のキー入力としてタイプする共通処理。
//
// ライン入力モード (LineInputMode) と、標準キーボード画面の IME 入力バー
// (日本語 IM がオンのとき自動で出る) の両方から使う。
//
// 文字 → スキャンコード変換は JIS 配列基準。大文字 (A-Z) や JIS の Shift 記号
// (! " # 等) は SHIFT 修飾を自動付与する。ASCII 以外は SJIS にエンコードし、
// X68000 の「コード入力」モードで 4 桁の 16 進として打ち込む。
// 送信前に LED トグル系 (かな/CAPS/ローマ字/コード入力/ひらがな/全角/INS) を
// 観測中の状態に基づいてオフに戻し、押下中の可能性がある修飾キーを強制 release
// する。これでクリーンな状態から打ち始める。

import 'package:flutter/foundation.dart';

import 'midi_service.dart';
import 'sjis_encoder.dart';
import 'x68k_shared_state.dart';

class X68kTextTyper {
  final MidiService midi;
  final int channel;
  final X68kKeyboardSharedState shared;

  X68kTextTyper({
    required this.midi,
    required this.channel,
    required this.shared,
  });

  // a-z (logical) を X68k スキャンコード A-Z の順で並べたもの。
  static const List<int> _letterScancodes = [
    0x1E, 0x2E, 0x2C, 0x20, 0x13, 0x21, 0x22, 0x23, // A B C D E F G H
    0x18, 0x24, 0x25, 0x26, 0x30, 0x2F, 0x19, 0x1A, // I J K L M N O P
    0x11, 0x14, 0x1F, 0x15, 0x17, 0x2D, 0x12, 0x2B, // Q R S T U V W X
    0x16, 0x2A, //                                    Y Z
  ];
  // 0-9 → 各スキャンコード
  static const List<int> _digitScancodes = [
    0x0B, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
  ];
  // それ以外の記号類。値は (scancode, 要 SHIFT) の record。
  static const Map<String, (int, bool)> _symbolMap = {
    // SHIFT 不要 (JIS 素押し)
    ' ': (0x35, false),
    '-': (0x0C, false),
    '^': (0x0D, false),
    '¥': (0x0E, false),
    '\\': (0x0E, false), // US の \ も JIS の ¥ に割り当て
    '@': (0x1B, false),
    '[': (0x1C, false),
    ';': (0x27, false),
    ':': (0x28, false),
    ']': (0x29, false),
    ',': (0x31, false),
    '.': (0x32, false),
    '/': (0x33, false),
    // SHIFT + その他キーで出る JIS 記号
    '!': (0x02, true),
    '"': (0x03, true),
    '#': (0x04, true),
    '\$': (0x05, true),
    '%': (0x06, true),
    '&': (0x07, true),
    "'": (0x08, true),
    '(': (0x09, true),
    ')': (0x0A, true),
    '=': (0x0C, true),
    '~': (0x0D, true),
    '|': (0x0E, true),
    '`': (0x1B, true),
    '{': (0x1C, true),
    '+': (0x27, true),
    '*': (0x28, true),
    '}': (0x29, true),
    '<': (0x31, true),
    '>': (0x32, true),
    '?': (0x33, true),
    '_': (0x34, true),
    // 制御文字
    '\n': (0x1D, false), // 改行 → RETURN
    '\t': (0x10, false), // タブ
  };

  /// 1 文字 → (scancode, SHIFT 要否)。マップ外なら null。
  static (int, bool)? charToScancode(String char) {
    if (char.length != 1) return null;
    final code = char.codeUnitAt(0);
    // a-z
    if (code >= 0x61 && code <= 0x7A) {
      return (_letterScancodes[code - 0x61], false);
    }
    // A-Z
    if (code >= 0x41 && code <= 0x5A) {
      return (_letterScancodes[code - 0x41], true);
    }
    // 0-9
    if (code >= 0x30 && code <= 0x39) {
      return (_digitScancodes[code - 0x30], false);
    }
    return _symbolMap[char];
  }

  // X68k スキャンコード定数
  static const int scReturn = 0x1D;
  static const int _scShift = 0x70;
  static const int scCtrl = 0x71;
  static const int _scCodeInput = 0x5C;
  // 送信前に強制 release する修飾キー (SHIFT/CTRL/OPT.1/OPT.2/XF1-5)
  static const List<int> _modifiersToRelease = [
    0x70, 0x71, 0x72, 0x73, 0x55, 0x56, 0x57, 0x58, 0x59,
  ];
  // 観測した LED のうち点灯中ならトグル押下でオフに戻す対象スキャンコード
  static const List<int> _toggleKeysToClear = [
    0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60,
  ];

  // タイミング
  static const Duration intraKeyDelay = Duration(milliseconds: 15);
  static const Duration interKeyDelay = Duration(milliseconds: 25);

  /// [text] をタイプする。戻り値は (送信した文字数, SJIS にマップできず
  /// スキップした文字数)。[onProgress] は (処理済み, 全体) で時々呼ばれる。
  Future<({int sent, int skipped})> typeText(
    String text, {
    void Function(int done, int total)? onProgress,
  }) async {
    final runes = text.runes.toList();
    int sent = 0;
    int skipped = 0;
    // コード入力モードの状態を追跡 (toggle なので前回の状態を覚えておく)。
    // resetState が toggle 系をすべてオフにするので false スタートで OK。
    bool inCodeMode = false;

    Future<void> ensureCodeMode(bool desired) async {
      if (inCodeMode == desired) return;
      debugPrint('[Typer] toggle code-input mode ${desired ? 'ON' : 'OFF'}');
      await sendOneChar(_scCodeInput, false);
      inCodeMode = desired;
      await Future.delayed(interKeyDelay);
    }

    debugPrint('[Typer] === send start: "$text" (${runes.length} codepoints) ===');
    await resetState();
    for (int i = 0; i < runes.length; i++) {
      final cp = runes[i];
      final raw = String.fromCharCode(cp);
      final asciiMapping = charToScancode(raw);
      if (asciiMapping != null) {
        // ASCII 系: コード入力モードを抜けてから直接送る
        await ensureCodeMode(false);
        debugPrint('[Typer]   send[$i] "$raw"'
            ' → scancode=0x${asciiMapping.$1.toRadixString(16).padLeft(2, '0')}'
            ' shift=${asciiMapping.$2}');
        await sendOneChar(asciiMapping.$1, asciiMapping.$2);
        sent++;
      } else {
        // SJIS にエンコードしてコード入力モードで送る。
        // 制御文字 (改行・タブ以外) はコード入力しても意味がないので送らない。
        final sjis = (cp < 0x20 || cp == 0x7F) ? null : SjisEncoder.encode(cp);
        if (sjis != null) {
          await ensureCodeMode(true);
          debugPrint('[Typer]   send[$i] "$raw"'
              ' U+${cp.toRadixString(16).padLeft(4, '0').toUpperCase()}'
              ' → SJIS=0x${sjis.toRadixString(16).padLeft(4, '0').toUpperCase()}');
          await _sendSjisHex(sjis);
          sent++;
        } else {
          debugPrint('[Typer]   skip[$i] "$raw"'
              ' U+${cp.toRadixString(16).padLeft(4, '0').toUpperCase()}'
              ' (SJIS にマップなし)');
          skipped++;
        }
      }
      if ((i & 0x07) == 0) onProgress?.call(i + 1, runes.length);
      await Future.delayed(interKeyDelay);
    }
    // 最後にコード入力モードを抜けておく
    await ensureCodeMode(false);
    debugPrint('[Typer] === send done: sent=$sent skipped=$skipped ===');
    return (sent: sent, skipped: skipped);
  }

  /// SJIS のコードを 4 桁 hex (16-bit 値 MSB から) として X68000 のキー入力で送る。
  /// コード入力モードに入っている前提。
  Future<void> _sendSjisHex(int sjisCode) async {
    for (int shift = 12; shift >= 0; shift -= 4) {
      final hex = (sjisCode >> shift) & 0x0F;
      await sendOneChar(_hexDigitToScancode(hex), false);
      await Future.delayed(intraKeyDelay);
    }
  }

  /// 0..F の hex 数字に対応する X68k スキャンコードを返す
  /// (0-9 は数字行、A-F は A-F キー、いずれも SHIFT 不要)。
  static int _hexDigitToScancode(int hex) {
    if (hex < 10) return _digitScancodes[hex];
    return _letterScancodes[hex - 10]; // A..F → letterScancodes[0..5]
  }

  /// 送信前に X68000 のキーボード状態をクリーンに戻す。
  Future<void> resetState() async {
    debugPrint('[Typer] reset: release modifiers');
    // 押下中の可能性がある修飾キーを強制 release (no-op の場合も含めて安全)。
    for (final code in _modifiersToRelease) {
      midi.sendNoteOff(channel, code);
    }
    await Future.delayed(intraKeyDelay);

    // 観測中の LED が点灯している toggle key を押してオフに戻す。
    final leds = shared.ledOn;
    debugPrint('[Typer] reset: ledOn snapshot = '
        '${leds.map((c) => '0x${c.toRadixString(16)}').join(',')}');
    for (final code in _toggleKeysToClear) {
      if (leds.contains(code)) {
        debugPrint('[Typer] reset: toggle off 0x${code.toRadixString(16)}');
        midi.sendNoteOn(channel, code, 127);
        await Future.delayed(intraKeyDelay);
        midi.sendNoteOff(channel, code);
        await Future.delayed(interKeyDelay);
      }
    }
  }

  /// CTRL を押したまま 1 キーを押して離す (emacs の C-x 等)。
  Future<void> sendCtrlChar(int scancode) async {
    midi.sendNoteOn(channel, scCtrl, 127);
    await Future.delayed(intraKeyDelay);
    midi.sendNoteOn(channel, scancode, 127);
    await Future.delayed(intraKeyDelay);
    midi.sendNoteOff(channel, scancode);
    await Future.delayed(intraKeyDelay);
    midi.sendNoteOff(channel, scCtrl);
  }

  /// 1 キーを押して離す (必要なら SHIFT で挟む)。
  Future<void> sendOneChar(int scancode, bool needShift) async {
    if (needShift) {
      midi.sendNoteOn(channel, _scShift, 127);
      await Future.delayed(intraKeyDelay);
    }
    midi.sendNoteOn(channel, scancode, 127);
    await Future.delayed(intraKeyDelay);
    midi.sendNoteOff(channel, scancode);
    if (needShift) {
      await Future.delayed(intraKeyDelay);
      midi.sendNoteOff(channel, _scShift);
    }
  }
}
