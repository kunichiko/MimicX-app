import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'dart:ui' show VoidCallback;
import 'package:flutter_midi_command/flutter_midi_command.dart';
import 'protocol.dart';

class MidiDeviceInfo {
  final String name;
  final String id;

  /// トランスポート種別 ("native"=USB, "BLE", "network" など、flutter_midi_command の
  /// MidiDevice.type をそのまま保持)。BLE はレイテンシ特性が違うため判定に使う。
  final String type;
  final MidiDevice _device;

  /// IDENTIFY_RESPONSE のパース結果 (識別前は null)
  DeviceIdentity? identity;

  MidiDeviceInfo({
    required this.name,
    required this.id,
    required this.type,
    required MidiDevice device,
  }) : _device = device;

  MidiDevice get device => _device;

  /// BLE-MIDI 経由のデバイスか。
  bool get isBle => type == 'BLE';
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

  // --- Heart Beat (1 秒間隔の接続生存通知) -----------------------------------
  // 操作画面 (joystick/x68k_keyboard/rename) に入ったら startHeartBeat() を呼び、
  // 1 秒ごとに CMD_HEART_BEAT を送って ACK を待つ。3 連続失敗 (= ~3 秒) で
  // onFailure callback を呼び、呼出側が「接続失敗」処理 (画面 pop + 再 scan) を行う。
  // 操作画面を出るときに stopHeartBeat() を呼ぶ。
  Timer? _heartBeatTimer;
  int _heartBeatConsecutiveFails = 0;
  VoidCallback? _onHeartBeatFailure;
  static const Duration heartBeatInterval = Duration(seconds: 1);
  /// HB ACK の許容遅延。1 秒間隔より短くしないと「次の HB が走り始めてから前の HB の
  /// timeout を見る」というラグでフェイルカウントが想定外に伸びる。
  static const Duration heartBeatTimeout = Duration(milliseconds: 900);
  static const int heartBeatMaxConsecutiveFails = 3;

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

  /// MIDI セットアップ変化通知ストリーム。
  /// "deviceAppeared" (USB が新規認識された) / "deviceConnected" / "deviceDisconnected"
  /// / "deviceFound" (BLE 発見) / "deviceLost" (BLE 消失) などの文字列が流れる。
  /// HomePage が自動再 scan のトリガに使う。
  Stream<String>? get onMidiSetupChanged => _midiCommand.onMidiSetupChanged;

  Future<List<MidiDeviceInfo>> scanDevices() async {
    final devices = await _midiCommand.devices ?? [];
    return devices
        .where((d) => !_excludedDeviceNamePatterns.any((p) => p.hasMatch(d.name)))
        .map((d) => MidiDeviceInfo(
              name: d.name,
              id: d.id,
              type: d.type,
              device: d,
            ))
        .toList();
  }

  // --- BLE-MIDI -------------------------------------------------------------
  // 標準 BLE-MIDI ペリフェラル (ESP32 等) を発見するには BLE central を起動して
  // スキャンを開始する必要がある。発見されたデバイスは scanDevices() の列挙
  // (MidiCommand.devices) に type=="BLE" として現れる。
  bool _bluetoothStarted = false;

  /// BLE central を起動しスキャンを開始する。Bluetooth が OFF / 権限拒否 /
  /// 非対応プラットフォームでは黙って無視する (USB は引き続き使える)。
  /// 複数回呼んでも安全 (central 起動は初回のみ)。
  Future<void> startBluetoothScanning() async {
    // 対象 4 プラットフォーム (Android / iOS / macOS / Windows) すべてで BLE-MIDI に対応:
    //   - Android: MidiManager BLE。scan のみ呼ぶ (理由は下記)。権限は plugin が自動要求。
    //   - iOS / macOS: CoreBluetooth。central 起動 → 初期化待ち → スキャン。
    //   - Windows: flutter_midi_command_windows (fork) が universal_ble (WinRT) で対応。
    //     iOS/macOS と同じ central 起動→スキャン経路を使う。
    // Bluetooth OFF / 権限拒否時は catch して USB のみで続行する。
    try {
      if (Platform.isAndroid) {
        // Android: scanForDevices が内部で BT 初期化・権限要求・スキャンを 1 回で行う
        // (権限付与後はプラグインが onRequestPermissionsResult から自動でスキャンを
        // 開始する)。startBluetoothCentral を続けて呼ぶと権限要求が二重になり、
        // 「Can request only one set of permissions at a time」で 2 回目が空の
        // grantResults を返し、プラグインの onRequestPermissionsResult が
        // grantResults[0] で ArrayIndexOutOfBoundsException を投げる。よって scan のみ。
        //
        // さらに Android は BLE スキャン開始の頻度制限 (5 回 / 30 秒) があり、毎回
        // startScan すると "scanning too frequently" で弾かれる。スキャンは一度
        // 始めれば動き続け、発見済みデバイスも保持されるので、セッション中 1 回だけ
        // 開始する (再スキャンは scanDevices() のデバイス列挙の読み直しで足りる)。
        if (_bluetoothStarted) return;
        _bluetoothStarted = true;
        await _midiCommand.startScanningForBluetoothDevices();
        return;
      }
      // iOS / macOS / Windows: central を起動し powered-on になるまで待ってからスキャン。
      if (!_bluetoothStarted) {
        await _midiCommand.startBluetoothCentral();
        _bluetoothStarted = true;
        await _midiCommand
            .waitUntilBluetoothIsInitialized()
            .timeout(const Duration(seconds: 5), onTimeout: () {});
      }
      await _midiCommand.startScanningForBluetoothDevices();
    } catch (_) {
      // Bluetooth 利用不可。USB のみで続行する。
    }
  }

  /// BLE スキャンを停止する。
  void stopBluetoothScanning() {
    try {
      _midiCommand.stopScanningForBluetoothDevices();
    } catch (_) {}
  }

  // --- トランスポート別パラメータ (protocol §2.4) ----------------------------
  // BLE-MIDI は USB-MIDI よりラウンドトリップが遅く分割もあるため、ACK タイムアウトと
  // HEART_BEAT 失敗許容回数を緩める。接続中デバイスの種別で自動的に切り替える。
  bool get _bleConnected => _connectedDevice?.type == 'BLE';

  /// 接続中トランスポートに応じた ACK タイムアウト (USB 100ms / BLE 400ms)。
  Duration get _ackTimeout =>
      _bleConnected ? const Duration(milliseconds: 400) : defaultAckTimeout;

  /// HEART_BEAT 連続失敗で切断とみなす回数 (USB 3 / BLE 5)。
  int get _heartBeatMaxFails =>
      _bleConnected ? 5 : heartBeatMaxConsecutiveFails;

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
    Duration? perAttemptTimeout,
    int? maxAttempts,
    Duration? retryDelay,
  }) async {
    // BLE は接続直後にサービス探索/購読が走るため初回応答が遅れがち。USB より
    // 長めのタイムアウトと多めのリトライにする (protocol §2.4)。
    perAttemptTimeout ??= _bleConnected
        ? const Duration(milliseconds: 600)
        : const Duration(milliseconds: 400);
    maxAttempts ??= _bleConnected ? 4 : 3;
    retryDelay ??= _bleConnected
        ? const Duration(milliseconds: 300)
        : const Duration(milliseconds: 200);
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
        timeout ?? _ackTimeout,
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
    // 接続が切れる以上 HB は無意味。callback 呼出も避けたいので _onHeartBeatFailure
    // も nil 化 (stopHeartBeat 経由)。
    stopHeartBeat();
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

  // sendNote/CC は HID 経由でアダプタへ送る。アダプタは CONNECTED 状態なら
  // 自動で activity 点滅 (青 High) するのでアプリ側からは何もしない。

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
  Future<AckResult> setPadMode(int mode) async {
    // BLE では接続直後の最初の往復が遅れ/取りこぼしになることがある (操作画面に入った
    // 直後の onEnter で呼ばれるため顕著)。タイムアウト (genericError) のときだけ
    // 数回リトライする。INVALID_VALUE など明確な NG はそのまま返す。
    final attempts = _bleConnected ? 3 : 1;
    AckResult result = AckResult(
      reqId: 0,
      status: AckStatus.genericError,
      origCmd: 0,
    );
    for (int i = 0; i < attempts; i++) {
      final reqId = _reqIdAllocator.allocate();
      result = await _sendAndWait(
        reqId: reqId,
        sysex: SysExBuilder.setConfig(reqId, 0x03, mode),
      );
      if (result.status != AckStatus.genericError) return result;
      if (i < attempts - 1) {
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
    return result;
  }

  /// X68000 キーボードの REMOTE 端子からリモコンコード [code] (0x01-0x1F) を
  /// 1 回発射するようファームに依頼する。
  ///
  /// SHIFT/OPT.2 + 特定キーの押下検出時や、独自リモコン UI からの発射に使う。
  /// レイテンシを抑えるため ACK は待たない (fire-and-forget)。ファームが未対応の
  /// バージョンの場合は UNKNOWN_COMMAND ACK が返るが無視される。
  void emitRemote(int code) {
    final reqId = _reqIdAllocator.allocate();
    sendSysEx(SysExBuilder.emitRemote(reqId, code));
  }

  /// ステータス LED の色を override 設定。R/G/B は 0-255。
  /// fire-and-forget。RGB=(255,255,255) はファーム側で override reset として扱われる。
  ///
  /// 注: 7bit → 8bit ファーム側展開は `(v<<1)|(v>>6)` なので 7bit `0x7F` は 255 にマップ。
  /// 最大輝度の白を出したいときは 254 を渡す ([resetLedOverride] と区別するため)。
  void setLedColor(int r, int g, int b) {
    final reqId = _reqIdAllocator.allocate();
    final r7 = (r >> 1) & 0x7F;
    final g7 = (g >> 1) & 0x7F;
    final b7 = (b >> 1) & 0x7F;
    sendSysEx(SysExBuilder.setLed(reqId, r7, g7, b7));
  }

  /// LED override をクリアする。ファームは状態色 (黄/緑/青) に戻し点滅もクリアする。
  void resetLedOverride() {
    final reqId = _reqIdAllocator.allocate();
    // (127, 127, 127) → ファーム側で (255, 255, 255) に展開 → reset sentinel
    sendSysEx(SysExBuilder.setLed(reqId, 0x7F, 0x7F, 0x7F));
  }

  /// ステータス LED の点滅速度 override を設定。speed は [LedBlinkSpeed] 定数。
  /// 色 override が掛かっていないときは値だけ保持される (ファーム側仕様)。
  void setLedBlink(int speed) {
    final reqId = _reqIdAllocator.allocate();
    sendSysEx(SysExBuilder.setLedBlink(reqId, speed));
  }

  // --- Heart Beat ----------------------------------------------------------

  /// HEART_BEAT を 1 秒間隔で送信開始する。3 回連続で ACK が返らなかった
  /// (= 約 3 秒間応答なし) 場合は [onFailure] が呼ばれる。
  ///
  /// 多重起動 (前のタイマーが残ったまま) は前タイマーを止めてから上書きする。
  /// 接続中の操作画面 / rename 画面に入るタイミングで呼ぶ。
  void startHeartBeat({required VoidCallback onFailure}) {
    _heartBeatTimer?.cancel();
    _heartBeatConsecutiveFails = 0;
    _onHeartBeatFailure = onFailure;
    _heartBeatTimer = Timer.periodic(heartBeatInterval, (_) => _tickHeartBeat());
  }

  /// HEART_BEAT 送信を停止する。画面を抜けるときに呼ぶ。
  void stopHeartBeat() {
    _heartBeatTimer?.cancel();
    _heartBeatTimer = null;
    _heartBeatConsecutiveFails = 0;
    _onHeartBeatFailure = null;
  }

  /// DISCONNECT (0x09) を送信して fire-and-forget。
  /// アダプタは即座に SCANNED に戻り override をクリアする。
  void sendDisconnect() {
    final reqId = _reqIdAllocator.allocate();
    sendSysEx(SysExBuilder.disconnect(reqId));
  }

  Future<void> _tickHeartBeat() async {
    // タイマー側からの async tick: 走行中にユーザーが画面を抜けたら timer は
    // cancel されているはずだが、in-flight な ACK 待ちが残ることがあるので
    // 多重実行に強い書き方にしておく。
    if (_heartBeatTimer == null) return;
    final reqId = _reqIdAllocator.allocate();
    final result = await _sendAndWait(
      reqId: reqId,
      sysex: SysExBuilder.heartBeat(reqId),
      timeout: heartBeatTimeout,
    );
    if (_heartBeatTimer == null) return;  // tick 完了前に stop された
    if (result.isOk) {
      _heartBeatConsecutiveFails = 0;
      return;
    }
    _heartBeatConsecutiveFails++;
    if (_heartBeatConsecutiveFails >= _heartBeatMaxFails) {
      // 失敗 callback を呼ぶ前に必ず timer を止めて多重通知を防ぐ。
      final cb = _onHeartBeatFailure;
      stopHeartBeat();
      cb?.call();
    }
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
    stopBluetoothScanning();
    _midiCommand.teardown();
  }
}
