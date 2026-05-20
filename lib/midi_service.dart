import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show VoidCallback;
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'protocol.dart';

class MidiDeviceInfo {
  final String name;
  final String id;
  final MidiDevice _device;

  /// IDENTIFY_RESPONSE のパース結果 (識別前は null)
  DeviceIdentity? identity;

  MidiDeviceInfo({required this.name, required this.id, required MidiDevice device})
      : _device = device;

  MidiDevice get device => _device;
}

class MidiService {
  final MidiCommand _midiCommand = MidiCommand();
  StreamSubscription<MidiPacket>? _rxSubscription;
  // 現在接続中の MidiDevice (disconnect 時にデバイス指定で切断するため保持)
  MidiDevice? _connectedDevice;
  VoidCallback? onDisconnect;

  // チャンネル割り当てを SysEx で受信したら通知
  void Function(DeviceIdentity)? onIdentifyResponse;

  // ターゲット機受信バイト通知 (TARGET_RX)
  //   midi_channel: 送信元の機能の MIDI チャンネル (0-indexed)
  //   byte: ターゲット機が送ってきた生バイト
  void Function(int midiChannel, int byte)? onTargetRx;

  // SysEx 受信用バッファ
  final List<int> _sysexBuf = [];
  bool _sysexReceiving = false;

  // req_id → 待機中 Completer。ACK / CAPABILITY_RESPONSE / CONFIG_RESPONSE 受信時に解決する
  final Map<int, Completer<AckResult>> _pendingAcks = {};
  final ReqIdAllocator _reqIdAllocator = ReqIdAllocator();

  /// API 呼び出しのデフォルトタイムアウト (プロトコル仕様 6.1.4 に準拠)
  static const Duration defaultAckTimeout = Duration(milliseconds: 100);

  // ジョイスティック Note 番号 (D-SUB 9pin 対応)
  static const int chJoystickDefault = 0;
  static const int chKeyboardDefault = 1;
  static const int chMouseDefault = 2;

  // 方向キー
  static const int noteUp = 1;
  static const int noteDown = 2;
  static const int noteLeft = 3;
  static const int noteRight = 4;
  // ATARI / MD 共通ボタン
  static const int noteA = 6;      // ATARI: TRIG-A / MD: A
  static const int noteB = 7;      // ATARI: TRIG-B / MD: B
  // MD 6ボタン拡張
  static const int noteC = 9;
  static const int noteStart = 10;
  static const int noteX = 11;
  static const int noteY = 12;
  static const int noteZ = 13;
  static const int noteMode = 14;
  // リブルラブル (XPD-1LR) 右側 D-pad。
  // 左側は noteUp/Down/Left/Right を流用し、右側のみ別 note を割り当てる。
  static const int noteUp2 = 15;
  static const int noteDown2 = 16;
  static const int noteLeft2 = 17;
  static const int noteRight2 = 18;

  // OS 内蔵で Mimic X になり得ないバーチャル MIDI デバイス。
  // Windows の "Microsoft GS Wavetable Synth" は出力専用ソフトシンセで
  // IDENTIFY を返せないため、スキャン段階で除外する。
  static final List<RegExp> _excludedDeviceNamePatterns = [
    RegExp(r'Microsoft GS Wavetable', caseSensitive: false),
  ];

  Future<List<MidiDeviceInfo>> scanDevices() async {
    final devices = await _midiCommand.devices ?? [];
    return devices
        .where((d) => !_excludedDeviceNamePatterns.any((p) => p.hasMatch(d.name)))
        .map((d) => MidiDeviceInfo(
              name: d.name,
              id: d.id,
              device: d,
            ))
        .toList();
  }

  Future<bool> connect(MidiDeviceInfo deviceInfo) async {
    try {
      // 前回セッションが残っている (iOS で画面回転後に device.connected=true の
      // まま port 側だけ閉じてしまうケースが観測された) と connectToDevice が
      // 空回りすることがあるので、明示的に一度切ってから繋ぎ直す。
      // 接続中でない場合の例外は無視する。
      try {
        _midiCommand.disconnectDevice(deviceInfo.device);
      } catch (_) {}
      // 前回 subscription が残っている可能性もあるので明示的にキャンセル
      await _rxSubscription?.cancel();
      _rxSubscription = null;
      // disconnect → connect の間に少し置いて library 側の状態が落ち着くのを待つ
      await Future.delayed(const Duration(milliseconds: 50));

      await _midiCommand.connectToDevice(deviceInfo.device);
      _connectedDevice = deviceInfo.device;
      _rxSubscription = _midiCommand.onMidiDataReceived?.listen(_onMidiReceived);
      // 接続直後にファームの状態を念のためクリアする。
      // - X68000 から給電されているとマイコンは USB 切断時もリセットされない
      //   ため、前回セッションで押されたままの note などが残っている可能性がある
      // - proto 0.4 (旧版) でも追加バイトは無視されるので安全
      // ACK は待たない (旧版は ACK を返さないので待つと無駄)。
      sendSysEx(SysExBuilder.reset(0));
      return true;
    } catch (e) {
      return false;
    }
  }

  /// IDENTIFY_REQUEST を送信し、レスポンスを待つ。
  ///
  /// USB-MIDI スタックが過渡的に応答を取りこぼすことがあるため、
  /// [maxAttempts] 回まで [perAttemptTimeout] のタイムアウトでリトライする。
  Future<DeviceIdentity?> identifyDevice({
    Duration perAttemptTimeout = const Duration(milliseconds: 400),
    int maxAttempts = 3,
    Duration retryDelay = const Duration(milliseconds: 200),
  }) async {
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      final completer = Completer<DeviceIdentity?>();
      final prevHandler = onIdentifyResponse;
      onIdentifyResponse = (id) {
        if (!completer.isCompleted) completer.complete(id);
      };
      sendSysEx(SysExBuilder.identifyRequest());
      final result = await completer.future.timeout(
        perAttemptTimeout,
        onTimeout: () => null,
      );
      onIdentifyResponse = prevHandler;
      if (result != null) return result;
      if (attempt < maxAttempts - 1) {
        await Future.delayed(retryDelay);
      }
    }
    return null;
  }

  void _onMidiReceived(MidiPacket packet) {
    final data = packet.data;
    for (final byte in data) {
      if (byte == 0xF0) {
        _sysexBuf.clear();
        _sysexBuf.add(byte);
        _sysexReceiving = true;
      } else if (_sysexReceiving) {
        _sysexBuf.add(byte);
        if (byte == 0xF7) {
          _processSysEx(List.unmodifiable(_sysexBuf));
          _sysexBuf.clear();
          _sysexReceiving = false;
        }
      }
      // 現状チャンネルメッセージ (Note/CC) のホスト方向受信は未使用
    }
  }

  void _processSysEx(List<int> sysex) {
    if (sysex.length < 5) return;
    if (sysex[1] != 0x7D || sysex[2] != 0x01) return;
    final cmd = sysex[3];
    if (cmd == SysExBuilder.cmdIdentifyRsp) {
      // IDENTIFY_RESPONSE はレガシーフォーマット (req_id なし)
      final id = DeviceIdentity.parse(sysex);
      if (id != null) onIdentifyResponse?.call(id);
    } else if (cmd == SysExBuilder.cmdTargetRx) {
      // F0 7D 01 05 <ch> <hi4> <lo4> F7 (req_id なし、非同期通知)
      if (sysex.length != 8) return;
      final ch = sysex[4];
      final byte = ((sysex[5] & 0x0F) << 4) | (sysex[6] & 0x0F);
      onTargetRx?.call(ch, byte);
    } else if (cmd == SysExBuilder.cmdAck) {
      // F0 7D 01 06 <req_id> <status> <orig_cmd> F7
      if (sysex.length < 8) return;
      _resolveAck(AckResult(
        reqId: sysex[4],
        status: sysex[5],
        origCmd: sysex[6],
      ));
    } else if (cmd == SysExBuilder.cmdCapabilityRsp ||
               cmd == SysExBuilder.cmdConfigRsp) {
      // F0 7D 01 <cmd> <req_id> <status> <payload...> F7
      if (sysex.length < 7) return;
      _resolveAck(AckResult(
        reqId: sysex[4],
        status: sysex[5],
        origCmd: cmd,
        payload: sysex.sublist(6, sysex.length - 1),
      ));
    }
  }

  void _resolveAck(AckResult result) {
    final completer = _pendingAcks.remove(result.reqId);
    completer?.complete(result);
  }

  /// req_id 付き SysEx を送信し、対応する ACK / レスポンスを req_id でマッチして
  /// 待つ。タイムアウト時は status=genericError の AckResult を返す。
  Future<AckResult> _sendAndWait({
    required int reqId,
    required List<int> sysex,
    Duration? timeout,
  }) async {
    final completer = Completer<AckResult>();
    _pendingAcks[reqId] = completer;
    sendSysEx(sysex);
    try {
      return await completer.future.timeout(
        timeout ?? defaultAckTimeout,
        onTimeout: () {
          _pendingAcks.remove(reqId);
          return AckResult(
            reqId: reqId,
            status: AckStatus.genericError,
            origCmd: 0,
          );
        },
      );
    } catch (_) {
      _pendingAcks.remove(reqId);
      return AckResult(
        reqId: reqId,
        status: AckStatus.genericError,
        origCmd: 0,
      );
    }
  }

  /// 個別デバイスを切断する。MIDI サブシステム自体は維持されるので、その後
  /// 同じインスタンスで再 scan / connect が可能。teardown は dispose 時のみ。
  ///
  /// teardown を毎回呼ぶと Android の MidiManager 登録状態が壊れて、
  /// 再接続後に IDENTIFY_RESPONSE が返ってこなくなる ("Not Mimic X compatible
  /// (no response)") ため、ここでは disconnectDevice のみ呼ぶ。
  void disconnect() {
    _rxSubscription?.cancel();
    _rxSubscription = null;
    // 待機中の ACK Completer をすべて解決して呼び出し側を unblock する
    for (final c in _pendingAcks.values) {
      if (!c.isCompleted) {
        c.complete(AckResult(
          reqId: 0,
          status: AckStatus.genericError,
          origCmd: 0,
        ));
      }
    }
    _pendingAcks.clear();
    final dev = _connectedDevice;
    if (dev != null) {
      _connectedDevice = null;
      _midiCommand.disconnectDevice(dev);
    }
  }

  // ---------------------------------------------------------------------------
  // 送信ヘルパー
  // ---------------------------------------------------------------------------

  void sendNoteOn(int channel, int note, int velocity) {
    final data = Uint8List.fromList([0x90 | (channel & 0x0F), note & 0x7F, velocity & 0x7F]);
    _midiCommand.sendData(data);
  }

  void sendNoteOff(int channel, int note) {
    final data = Uint8List.fromList([0x80 | (channel & 0x0F), note & 0x7F, 0x00]);
    _midiCommand.sendData(data);
  }

  void sendCC(int channel, int cc, int value) {
    final data = Uint8List.fromList([0xB0 | (channel & 0x0F), cc & 0x7F, value & 0x7F]);
    _midiCommand.sendData(data);
  }

  void sendSysEx(List<int> data) {
    _midiCommand.sendData(Uint8List.fromList(data));
  }

  // パッドモード設定 (SysEx SET_CONFIG)
  // 0 = ATARI, 1 = MD 6B, 2 = Libble Rabble (XPD-1LR)
  // req_id を採番し、ACK を待って結果を返す。タイムアウト or status != OK なら
  // isOk == false の AckResult が返る。
  Future<AckResult> setPadMode(int mode) {
    final reqId = _reqIdAllocator.allocate();
    return _sendAndWait(
      reqId: reqId,
      sysex: SysExBuilder.setConfig(reqId, 0x03, mode),
    );
  }

  // 任意 channel への送信ヘルパー (互換)
  void joystickPress(int note, {int channel = chJoystickDefault}) =>
      sendNoteOn(channel, note, 127);
  void joystickRelease(int note, {int channel = chJoystickDefault}) =>
      sendNoteOff(channel, note);

  /// MidiService 自体を破棄する。アプリ終了時に 1 度だけ呼ぶ想定。
  /// teardown は MIDI サブシステム全体を解放するため、ここでだけ呼ぶ。
  void dispose() {
    disconnect();
    _midiCommand.teardown();
  }
}
