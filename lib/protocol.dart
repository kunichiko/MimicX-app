// ===================================================================================
// Mimic X プロトコル定数とパーサ
// ===================================================================================
// プロトコル仕様: MimicX-protocol v0.8.0
// ===================================================================================

/// このアプリがサポートするプロトコルのバージョン範囲。
///
/// - [minMajor].[minMinor]: 最低サポートバージョン。これ未満は「未対応」で接続拒否
/// - [knownLatestMajor].[knownLatestMinor]: アプリが明示的に知っている最新版。
///   これより新しいファームと話す場合は「互換性がない可能性」警告を出す
///   (機能の一部が欠落する可能性あり)
///
/// 通常は両者を同じ値にしておく。アプリ更新で新プロトコル対応した場合のみ
/// knownLatest を引き上げる。
class MinSupportedProtocol {
  // 最低サポートバージョン。0.7 でアダプタの Chip UID シリアルが IDENTIFY_RSP に
  // 含まれるようになり、ニックネーム永続化や LED 制御 (SET_LED / SET_LED_BLINK)
  // のためにこのアプリは 0.7 以降必須とする。
  static const int minMajor = 0;
  static const int minMinor = 7;

  // アプリが知っている最新プロトコルバージョン。
  // 0.8 でトランスポート非依存化 + BLE-MIDI バインディングに対応 (§2.3/§2.4)。
  static const int knownLatestMajor = 0;
  static const int knownLatestMinor = 8;

  // 旧 API 互換用 (minor が同じなら同一)
  static const int major = minMajor;
  static const int minor = minMinor;

  static String get label => '$minMajor.$minMinor';
  static String get knownLatestLabel => '$knownLatestMajor.$knownLatestMinor';

  /// (major, minor) が最低要件を満たすか判定。
  /// 同 major なら minor 以上、major が大きければ常に OK (将来互換)。
  static bool meets(int protoMajor, int protoMinor) {
    if (protoMajor > minMajor) return true;
    if (protoMajor < minMajor) return false;
    return protoMinor >= minMinor;
  }

  /// デバイスのバージョンがアプリの知っている最新版より新しいか。
  /// true ならアプリ側に新プロトコルの解釈ロジックがないため警告対象。
  static bool isNewerThanKnown(int protoMajor, int protoMinor) {
    if (protoMajor > knownLatestMajor) return true;
    if (protoMajor < knownLatestMajor) return false;
    return protoMinor > knownLatestMinor;
  }
}

/// SysEx ACK / レスポンスの status コード (プロトコル仕様 6.1.3)
class AckStatus {
  static const int ok = 0x00;
  static const int unknownCommand = 0x01;
  static const int unknownKey = 0x02;
  static const int invalidValue = 0x03;
  static const int genericError = 0x7F;

  static String label(int v) {
    switch (v) {
      case ok: return 'OK';
      case unknownCommand: return 'UNKNOWN_COMMAND';
      case unknownKey: return 'UNKNOWN_KEY';
      case invalidValue: return 'INVALID_VALUE';
      case genericError: return 'GENERIC_ERROR';
      default: return 'Unknown(0x${v.toRadixString(16)})';
    }
  }
}

/// SysEx リクエストへの応答 (ACK / 専用レスポンス) を表す共通型。
class AckResult {
  final int reqId;
  final int status;
  /// ACK (0x06) の場合: 元コマンド値、それ以外: 応答自身のコマンド値
  final int origCmd;
  final List<int> payload;

  AckResult({
    required this.reqId,
    required this.status,
    required this.origCmd,
    this.payload = const [],
  });

  bool get isOk => status == AckStatus.ok;
}

class HidType {
  static const int unknown = 0x00;
  static const int keyboard = 0x01;
  static const int joystick = 0x02;
  static const int mouse = 0x03;
  static const int custom = 0x10;

  static String label(int v) {
    switch (v) {
      case keyboard: return 'Keyboard';
      case joystick: return 'Joystick';
      case mouse: return 'Mouse';
      case custom: return 'Custom';
      default: return 'Unknown(0x${v.toRadixString(16)})';
    }
  }
}

class TargetSystem {
  static const int generic = 0x00;
  static const int atari = 0x01;
  static const int x68000 = 0x02;
  static const int pc98 = 0x03;
  static const int msx = 0x04;
  static const int fmTowns = 0x05;
  static const int pc88 = 0x06;
  static const int apple2 = 0x07;
  static const int c64 = 0x08;
  static const int amiga = 0x09;
  static const int zx = 0x0A;
  static const int pcAt = 0x10;
  static const int pcXt = 0x11;
  static const int megaDrive = 0x40;

  static String label(int v) {
    switch (v) {
      case atari: return 'ATARI';
      case x68000: return 'X68000';
      case pc98: return 'PC-9801';
      case msx: return 'MSX';
      case fmTowns: return 'FM TOWNS';
      case pc88: return 'PC-8801';
      case apple2: return 'Apple II';
      case c64: return 'C64';
      case amiga: return 'Amiga';
      case zx: return 'ZX Spectrum';
      case pcAt: return 'IBM PC/AT';
      case pcXt: return 'IBM PC XT';
      case megaDrive: return 'Mega Drive';
      case generic: return 'Generic';
      default: return 'Unknown(0x${v.toRadixString(16)})';
    }
  }
}

/// 1 つの MIDI チャンネルに割り当てられた HID 機能
class ChannelAssignment {
  final int midiChannel;
  final int hidType;
  final int targetSystem;

  ChannelAssignment({
    required this.midiChannel,
    required this.hidType,
    required this.targetSystem,
  });

  String get hidTypeLabel => HidType.label(hidType);
  String get targetLabel => TargetSystem.label(targetSystem);

  @override
  String toString() =>
      'ch${midiChannel + 1}: $hidTypeLabel ($targetLabel)';
}

/// IDENTIFY_RESPONSE のパース結果
class DeviceIdentity {
  final int protocolMajor;
  final int protocolMinor;
  final int firmwareMajor;
  final int firmwareMinor;
  final int firmwarePatch;
  final List<ChannelAssignment> channels;
  /// アダプタ個体のシリアル (Chip UID 64bit を 16 文字 ASCII hex 大文字で表現)。
  /// プロトコル 0.7 未満では IDENTIFY_RSP に存在しないので空文字を入れる。
  /// アプリ自身は 0.7 を minMinor として要求するため通常は 16 文字保証される。
  final String serial;
  final String deviceName;

  DeviceIdentity({
    required this.protocolMajor,
    required this.protocolMinor,
    required this.firmwareMajor,
    required this.firmwareMinor,
    required this.firmwarePatch,
    required this.channels,
    required this.serial,
    required this.deviceName,
  });

  String get protocolVersion => '$protocolMajor.$protocolMinor';
  String get firmwareVersion => '$firmwareMajor.$firmwareMinor.$firmwarePatch';

  /// IDENTIFY_RESPONSE を SysEx 全体 (F0..F7) からパース
  ///
  /// レイアウト (proto 0.7+):
  /// ```
  ///   F0 7D 01 02
  ///     <protocol_major> <protocol_minor>
  ///     <fw_major> <fw_minor> <fw_patch>
  ///     <num_channels>
  ///     <ch> <type> <target>  ... (num_channels 個)
  ///     <serial[16] ASCII hex>
  ///     <name ASCII...>
  ///   F7
  /// ```
  ///
  /// proto 0.6 以下は serial[16] が無く name が直接続く。古いファームは
  /// MinSupportedProtocol で接続拒否するが、安全のため後方互換パースも残す。
  static DeviceIdentity? parse(List<int> sysex) {
    if (sysex.length < 11) return null;
    if (sysex.first != 0xF0 || sysex.last != 0xF7) return null;
    if (sysex[1] != 0x7D || sysex[2] != 0x01 || sysex[3] != 0x02) return null;

    int p = 4;
    final protoMaj = sysex[p++];
    final protoMin = sysex[p++];
    final fwMaj = sysex[p++];
    final fwMin = sysex[p++];
    final fwPatch = sysex[p++];
    final numCh = sysex[p++];

    final channels = <ChannelAssignment>[];
    for (int i = 0; i < numCh; i++) {
      if (p + 3 > sysex.length - 1) return null;
      channels.add(ChannelAssignment(
        midiChannel: sysex[p++],
        hidType: sysex[p++],
        targetSystem: sysex[p++],
      ));
    }

    // serial[16]: proto 0.7+ のみ存在。それ以前は空文字を入れて旧 layout として扱う。
    String serial = '';
    final hasSerial = (protoMaj > 0 || (protoMaj == 0 && protoMin >= 7)) &&
        (p + 16 <= sysex.length - 1);
    if (hasSerial) {
      serial = String.fromCharCodes(sysex.sublist(p, p + 16));
      p += 16;
    }

    final nameBytes = sysex.sublist(p, sysex.length - 1);
    final name = String.fromCharCodes(nameBytes);

    return DeviceIdentity(
      protocolMajor: protoMaj,
      protocolMinor: protoMin,
      firmwareMajor: fwMaj,
      firmwareMinor: fwMin,
      firmwarePatch: fwPatch,
      channels: channels,
      serial: serial,
      deviceName: name,
    );
  }
}

/// ステータス LED (PB0 WS2812B) の点滅速度 (プロトコル仕様 6.9)
class LedBlinkSpeed {
  static const int none = 0x00;  // 点滅しない (常時点灯)
  static const int slow = 0x01;  // 1 Hz
  static const int mid  = 0x02;  // 2 Hz
  static const int high = 0x03;  // 4 Hz
}

/// SysEx コマンドビルダ
class SysExBuilder {
  static const int mfrId = 0x7D;
  static const int subId = 0x01;
  static const int cmdIdentifyReq = 0x01;
  static const int cmdIdentifyRsp = 0x02;
  static const int cmdCapabilityReq = 0x03;
  static const int cmdCapabilityRsp = 0x04;
  static const int cmdTargetRx = 0x05;   // デバイス→ホスト: ターゲット機からの受信バイト
  static const int cmdAck = 0x06;        // デバイス→ホスト: 専用レスポンス無しコマンドの ACK
  static const int cmdEmitRemote = 0x07; // ホスト→デバイス: REMOTE 端子からリモコンコード発射
  static const int cmdHeartBeat = 0x08;  // ホスト→デバイス: 接続生存通知 (1 秒間隔)
  static const int cmdDisconnect = 0x09; // ホスト→デバイス: 選択終了。即座に SCANNED 復帰
  static const int cmdSetConfig = 0x10;
  static const int cmdGetConfig = 0x11;
  static const int cmdConfigRsp = 0x12;
  static const int cmdSetLed = 0x20;      // ホスト→デバイス: PB0 LED の色を設定
  static const int cmdSetLedBlink = 0x21; // ホスト→デバイス: PB0 LED の点滅速度を設定
  static const int cmdReset = 0x7F;

  /// IDENTIFY はブートストラップのため req_id を持たない (プロトコル 6.3)
  static List<int> identifyRequest() =>
      [0xF0, mfrId, subId, cmdIdentifyReq, 0xF7];

  static List<int> capabilityRequest(int reqId) =>
      [0xF0, mfrId, subId, cmdCapabilityReq, reqId & 0x7F, 0xF7];

  static List<int> setConfig(int reqId, int key, int value) =>
      [0xF0, mfrId, subId, cmdSetConfig, reqId & 0x7F, key & 0x7F, value & 0x7F, 0xF7];

  static List<int> getConfig(int reqId, int key) =>
      [0xF0, mfrId, subId, cmdGetConfig, reqId & 0x7F, key & 0x7F, 0xF7];

  static List<int> reset(int reqId) =>
      [0xF0, mfrId, subId, cmdReset, reqId & 0x7F, 0xF7];

  /// EMIT_REMOTE (0x07): X68000 キーボードの REMOTE 端子から SHARP 12-bit
  /// リモコンコードを送出させる。code は 0x01-0x1F。
  static List<int> emitRemote(int reqId, int code) =>
      [0xF0, mfrId, subId, cmdEmitRemote, reqId & 0x7F, code & 0x7F, 0xF7];

  /// HEART_BEAT (0x08): 接続生存通知。デバイス側は ACK を返しつつ
  /// 内部状態を CONNECTED に保持する。
  static List<int> heartBeat(int reqId) =>
      [0xF0, mfrId, subId, cmdHeartBeat, reqId & 0x7F, 0xF7];

  /// DISCONNECT (0x09): 選択終了。デバイス側は ACK を返しつつ即座に
  /// SCANNED (緑) に戻り override をクリアする。
  static List<int> disconnect(int reqId) =>
      [0xF0, mfrId, subId, cmdDisconnect, reqId & 0x7F, 0xF7];

  /// SET_LED (0x20): PB0 ステータス LED の色を設定。R/G/B は 0-127 (7bit)。
  /// デバイス側で `(v<<1)|(v>>6)` により 8bit (0-255) に拡張される。
  static List<int> setLed(int reqId, int r, int g, int b) => [
        0xF0, mfrId, subId, cmdSetLed,
        reqId & 0x7F, r & 0x7F, g & 0x7F, b & 0x7F, 0xF7,
      ];

  /// SET_LED_BLINK (0x21): PB0 ステータス LED の点滅速度を設定 (色は変えない)。
  /// [speed] は [LedBlinkSpeed] 定数。
  static List<int> setLedBlink(int reqId, int speed) => [
        0xF0, mfrId, subId, cmdSetLedBlink, reqId & 0x7F, speed & 0x7F, 0xF7,
      ];
}

/// 0x00〜0x7F を巡回する request ID アロケータ。
/// 0x00 は IDENTIFY や "expectation 不要" 用に予約し、通常は 1〜127 を払い出す。
class ReqIdAllocator {
  int _next = 1;
  int allocate() {
    final id = _next;
    _next = (_next + 1) & 0x7F;
    if (_next == 0) _next = 1;
    return id;
  }
}
