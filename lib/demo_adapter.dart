// ===================================================================================
// デモ用の仮想アダプタ
// ===================================================================================
// 実機 (USB / BLE の Mimic X アダプタ) が無い環境 — iOS シミュレータ、App Store
// 審査、展示でのデモなど — でも接続後の画面を一通り操作できるようにするための
// ソフトウェアエミュレータ。
//
// MidiService の送信経路で「接続先がデモアダプタ」のときだけプラグインを通さず
// ここへバイト列を渡し、ファームと同じ形式の応答 (IDENTIFY_RESPONSE / ACK /
// CONFIG_RESPONSE / TARGET_RX など) を少し遅らせて受信経路へ戻す。アプリ側の
// プロトコル処理 (req_id 照合・タイムアウト・HB) は実機と同じコードがそのまま動く。
//
// 実機の挙動を厳密に再現するものではない (ターゲット機は存在しないので、ノートは
// 受け取って捨てるだけ)。X68000 キーボードについては LED 状態の問い合わせ (0xFF) と
// LED トグルキーの押下に応答し、キーボード画面の LED 表示まで確認できるようにする。
// ===================================================================================

import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'protocol.dart';

/// デモアダプタを一覧に出すかどうかの設定 (端末ローカルに保存)。
/// 既定は OFF。about 画面のスイッチで切り替える。
class DemoModeStore {
  static const String _key = 'demo_adapters_enabled';

  static Future<bool> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_key) ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> save(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, enabled);
    } catch (_) {
      // 保存失敗は致命的ではない (今回のセッションには反映済み)
    }
  }
}

/// デモアダプタの構成 (どの機能を持つアダプタとして振る舞うか)。
enum DemoAdapterKind {
  /// ATARI ジョイスティック 1ch (atari-joystick 基板相当)
  joystick,

  /// X68000 キーボード + マウス (x68k キーボード基板相当)
  x68000,

  /// ジョイスティック + X68000 キーボード/マウス (Combined 基板相当)
  combined,
}

class DemoAdapter {
  DemoAdapter(this.kind);

  final DemoAdapterKind kind;

  /// MidiDevice.type に入れる値。実機の 'native' / 'BLE' と区別する。
  static const String deviceType = 'demo';

  /// デバイス id の接頭辞。プラグインの id と衝突しない文字列にする。
  static const String idPrefix = 'mimicx-demo:';

  String get id => '$idPrefix${kind.name}';

  String get name {
    switch (kind) {
      case DemoAdapterKind.joystick:
        return 'Mimic X Demo (Joystick)';
      case DemoAdapterKind.x68000:
        return 'Mimic X Demo (X68000)';
      case DemoAdapterKind.combined:
        return 'Mimic X Demo (Combined)';
    }
  }

  /// IDENTIFY_RESPONSE の serial。ニックネーム保存のキーになるので構成ごとに固定。
  String get serial {
    switch (kind) {
      case DemoAdapterKind.joystick:
        return 'DE00000000000001';
      case DemoAdapterKind.x68000:
        return 'DE00000000000002';
      case DemoAdapterKind.combined:
        return 'DE00000000000003';
    }
  }

  // チャンネル割り当ては実機ファームの既定値に合わせる
  // (joystick=ch1, keyboard=ch2, mouse=ch3。0-indexed で 0/1/2)。
  List<ChannelAssignment> get channels {
    final joy = ChannelAssignment(
      midiChannel: 0,
      hidType: HidType.joystick,
      targetSystem: TargetSystem.atari,
    );
    final kb = ChannelAssignment(
      midiChannel: 1,
      hidType: HidType.keyboard,
      targetSystem: TargetSystem.x68000,
    );
    final mouse = ChannelAssignment(
      midiChannel: 2,
      hidType: HidType.mouse,
      targetSystem: TargetSystem.x68000,
    );
    switch (kind) {
      case DemoAdapterKind.joystick:
        return [joy];
      case DemoAdapterKind.x68000:
        return [kb, mouse];
      case DemoAdapterKind.combined:
        return [joy, kb, mouse];
    }
  }

  /// 応答をアプリへ返すコールバック (MidiService の受信処理に繋がる)。
  void Function(List<int> bytes)? onReply;

  /// 実機 (USB) 程度の往復遅延を模す。
  static const Duration _latency = Duration(milliseconds: 8);

  // --- 仮想 X68000 の LED 状態 ------------------------------------------------
  // bit0-6 = かな/ローマ字/コード入力/CAPS/INS/ひらがな/全角、0=点灯 1=消灯
  // (X68000 の LED 制御コマンドと同じ極性)。起動時は全消灯。
  int _ledBits = 0x7F;

  /// LED トグルキーのスキャンコード → LED ビット位置。
  static const Map<int, int> _ledToggleKeys = {
    0x5A: 0, // かな
    0x5B: 1, // ローマ字
    0x5C: 2, // コード入力
    0x5D: 3, // CAPS
    0x5E: 4, // INS
    0x5F: 5, // ひらがな
    0x60: 6, // 全角
  };

  /// 接続時に呼ぶ。前回セッションの状態を持ち越さない。
  void reset() {
    _ledBits = 0x7F;
  }

  // --- 受信 (アプリ → アダプタ) ---------------------------------------------

  final List<int> _sysexBuf = [];
  bool _inSysex = false;

  /// アプリが送ったバイト列を受け取る。SysEx は F0..F7 で区切って処理し、
  /// それ以外はチャンネルメッセージとして 3 バイト単位で処理する。
  void receive(List<int> data) {
    int i = 0;
    while (i < data.length) {
      final b = data[i];
      if (b == 0xF0) {
        _sysexBuf
          ..clear()
          ..add(b);
        _inSysex = true;
        i++;
        continue;
      }
      if (_inSysex) {
        _sysexBuf.add(b);
        if (b == 0xF7) {
          _inSysex = false;
          _handleSysEx(List<int>.of(_sysexBuf));
        }
        i++;
        continue;
      }
      if ((b & 0x80) != 0 && i + 2 < data.length) {
        _handleChannelMessage(b, data[i + 1], data[i + 2]);
        i += 3;
        continue;
      }
      i++;
    }
  }

  void _handleChannelMessage(int status, int d1, int d2) {
    final type = status & 0xF0;
    final ch = status & 0x0F;
    final kbCh = _keyboardChannel;
    if (kbCh == null || ch != kbCh) return;
    final isNoteOn = type == 0x90 && d2 != 0;
    final isNoteOff = type == 0x80 || (type == 0x90 && d2 == 0);
    // LED 状態の問い合わせ: note 0x7F の note off = キーボードから 0xFF。
    // 実機の X68000 は現状の LED 制御コマンドを返す。
    if (isNoteOff && d1 == 0x7F) {
      _sendTargetRx(kbCh, 0x80 | _ledBits);
      return;
    }
    // LED トグルキーの押下で LED を反転し、X68000 と同様に LED 制御コマンドを返す。
    if (isNoteOn) {
      final bit = _ledToggleKeys[d1];
      if (bit != null) {
        _ledBits ^= (1 << bit);
        _sendTargetRx(kbCh, 0x80 | _ledBits);
      }
    }
  }

  int? get _keyboardChannel {
    for (final c in channels) {
      if (c.hidType == HidType.keyboard) return c.midiChannel;
    }
    return null;
  }

  void _handleSysEx(List<int> sx) {
    if (sx.length < 5) return;
    if (sx[1] != SysExBuilder.mfrId || sx[2] != SysExBuilder.subId) return;
    final cmd = sx[3];
    if (cmd == SysExBuilder.cmdIdentifyReq) {
      _reply(_identifyResponse());
      return;
    }
    // ここから先は req_id 付きのコマンド
    if (sx.length < 6) return;
    final reqId = sx[4];
    switch (cmd) {
      case SysExBuilder.cmdHeartBeat:
      case SysExBuilder.cmdDisconnect:
      case SysExBuilder.cmdReset:
      case SysExBuilder.cmdSetLed:
      case SysExBuilder.cmdSetLedBlink:
      case SysExBuilder.cmdEmitRemote:
      case SysExBuilder.cmdSetConfig:
        _reply(_ack(reqId, AckStatus.ok, cmd));
        break;
      default:
        // GET_CONFIG / CAPABILITY / BRIDGE_* など (アプリは未使用、または
        // ブリッジ専用): USB 直結の単一チップ構成と同じく未対応を返す
        _reply(_ack(reqId, AckStatus.unknownCommand, cmd));
    }
  }

  List<int> _ack(int reqId, int status, int origCmd) => [
        0xF0, SysExBuilder.mfrId, SysExBuilder.subId, SysExBuilder.cmdAck,
        reqId & 0x7F, status & 0x7F, origCmd & 0x7F, 0xF7,
      ];

  List<int> _identifyResponse() {
    final chs = channels;
    return [
      0xF0, SysExBuilder.mfrId, SysExBuilder.subId, SysExBuilder.cmdIdentifyRsp,
      MinSupportedProtocol.knownLatestMajor,
      MinSupportedProtocol.knownLatestMinor,
      // fw 0.0.0 = 実在しない版数。デモであることが一覧からも分かるようにする
      0, 0, 0,
      chs.length,
      for (final c in chs) ...[c.midiChannel, c.hidType, c.targetSystem],
      ...serial.codeUnits,
      ...name.codeUnits,
      0xF7,
    ];
  }

  void _sendTargetRx(int ch, int byte) {
    _reply([
      0xF0, SysExBuilder.mfrId, SysExBuilder.subId, SysExBuilder.cmdTargetRx,
      ch & 0x0F, (byte >> 4) & 0x0F, byte & 0x0F, 0xF7,
    ]);
  }

  void _reply(List<int> bytes) {
    Timer(_latency, () => onReply?.call(bytes));
  }
}
