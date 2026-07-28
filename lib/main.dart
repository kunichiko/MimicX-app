import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'about_page.dart';
import 'device_nickname_store.dart';
import 'device_rename_page.dart';
import 'l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'midi_service.dart';
import 'protocol.dart';
import 'joystick_page.dart';
import 'orientation_helper.dart';
import 'windows_ime.dart';
import 'x68k_keyboard_page.dart';

void main() {
  // JoystickSettings はモード毎にインスタンスを持って onEnter で lazy load する。
  // (以前はグローバル singleton をここで preload していた)
  WidgetsFlutterBinding.ensureInitialized();
  // Windows: 既定で IME を無効化しておく。ライン入力モードに入ったときだけ
  // ON にして抜けるときに OFF に戻す。
  WindowsIme.setEnabled(false);
  runApp(const SmartRetroHidApp());
}

class SmartRetroHidApp extends StatelessWidget {
  const SmartRetroHidApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      onGenerateTitle: (ctx) => AppLocalizations.of(ctx)!.appTitle,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      // 端末ロケールが ja なら日本語、それ以外はデフォルトの英語にフォールバック。
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  final MidiService _midi = MidiService();
  List<MidiDeviceInfo> _devices = [];
  /// serial → ユーザー設定ニックネーム (未設定なら entry なし)。
  /// scanAndIdentify で identity 取得後にロードする。
  final Map<String, String> _nicknames = {};

  /// device id → 識別済み DeviceIdentity のキャッシュ。
  /// 再 scan のたびに各デバイスへ connect→identify→disconnect すると、特に
  /// Android BLE では接続/切断が MidiManager の device add/remove (deviceFound /
  /// deviceLost) を発火し、それが自動再 scan を誘発して無限ループ (スキャンが回り
  /// 続ける) になる。識別はデバイスごとに 1 回でよいので、既知 id は接続せず
  /// キャッシュを使う。
  final Map<String, DeviceIdentity> _identityCache = {};

  /// 識別に失敗し続けるデバイスのセッション内クールダウン (deviceId → 状態)。
  /// ボンド不一致で必ず切断されるデバイスや Mimic X ではない MIDI 機器が、
  /// 自動再スキャンのたびに接続試行を専有して他のデバイスの識別を遅らせる
  /// のを防ぐ。連続失敗 2 回目から 15s × 2^n (上限 120s) スキップする。
  final Map<String, ({int fails, DateTime until})> _identifyCooldown = {};

  bool _scanning = false;
  /// _openDevice の connect+identify 中だけ true。Android で connectToDevice が
  /// 数秒かかるため、その間にホーム画面に半透明オーバーレイ + スピナーを出して
  /// ユーザに進捗を示す。</_routeToChannel 呼出前に false に戻すので、操作画面
  /// 自体の表示遅延には影響しない。
  bool _opening = false;

  /// 自身の connect/disconnect で発火するため再 scan のトリガにしてはいけない
  /// setup イベント名 (これらが返ってきたら無視し、それ以外は全部再 scan する)。
  /// iOS/macOS の USB 挿抜は friendly な "deviceAppeared" ではなく CoreMIDI の
  /// 生 messageID 文字列 (例: "msgObjectAdded") が流れるため、ホワイトリストではなく
  /// ブラックリストで判定する。
  static const Set<String> _ignoredSetupEvents = {
    'deviceConnected',
    'deviceDisconnected',
  };

  /// Android の MidiManager.DeviceCallback.onDeviceStatusChanged は、port の
  /// open/close 数が変わるたびに MidiDeviceStatus.toString() を流す。実装は
  /// AOSP MidiDeviceStatus.java の通り常に "mInputPortOpen=[...] " で始まる
  /// (例: "mInputPortOpen=[true] mOutputPortOpenCount=[1]")。
  /// 自分の connect/disconnect でも発火するため、これを再 scan トリガに
  /// すると進行中の接続を `_scanAndIdentify` の `_midi.connect→disconnect` で
  /// 破壊してしまう (Android では connectToDevice が固定 2500ms 遅延で完了する
  /// 仕様なので、その間に確実に再 scan が走ってしまう)。
  /// 物理 USB 挿抜は別途 onDeviceAdded/Removed が "deviceFound"/"deviceLost" を
  /// 流すのでカバーされる。
  static const String _androidStatusEventPrefix = 'mInputPortOpen=';

  StreamSubscription<String>? _midiSetupSub;
  /// MIDI setup イベントは USB 列挙で in/out 等が連続して飛んでくることがあるので
  /// 短く debounce してから 1 回だけ再 scan する。
  Timer? _autoRescanDebounce;

  @override
  void initState() {
    super.initState();
    // ホーム画面は OS の自動回転に追従させる (横持ち利用も多いため固定しない)。
    OrientationHelper.unlock();

    _midi.onDisconnect = () {
      if (mounted) setState(() {});
    };
    // アプリが BG→FG 復帰したときの自動再スキャンを購読する。
    WidgetsBinding.instance.addObserver(this);
    // USB 挿抜などで MIDI 構成が変わったらイベント駆動で再 scan する。
    _midiSetupSub = _midi.onMidiSetupChanged?.listen(_onMidiSetupChanged);
    // 起動時に自動スキャン
    Future.microtask(_scanAndIdentify);
  }

  @override
  void dispose() {
    _autoRescanDebounce?.cancel();
    _midiSetupSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _midi.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _maybeAutoRescan();
  }

  void _onMidiSetupChanged(String event) {
    if (_ignoredSetupEvents.contains(event)) return;
    if (event.startsWith(_androidStatusEventPrefix)) return;
    _autoRescanDebounce?.cancel();
    _autoRescanDebounce =
        Timer(const Duration(milliseconds: 400), _maybeAutoRescan);
  }

  /// 自動再 scan の発火条件を満たすかチェックして scanAndIdentify を呼ぶ。
  /// - HomePage が最上層の route であること (操作画面に居る間は MIDI 接続を
  ///   壊さないよう何もしない)
  /// - 既に scan 中でないこと
  void _maybeAutoRescan() {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route?.isCurrent != true) return;
    if (_scanning) return;
    _scanAndIdentify();
  }

  Future<void> _scanAndIdentify() async {
    setState(() => _scanning = true);
    // BLE-MIDI 機 (ESP32 等) を列挙対象にするため central 起動 + スキャンを行う。
    // Bluetooth OFF / 権限拒否時は内部で無視され USB のみで続行する。BLE 機は
    // 発見が非同期なので、初回で出なくても "deviceFound" イベントで自動再 scan される。
    await _midi.startBluetoothScanning();
    final devices = await _midi.scanDevices();

    // 各デバイスに対して接続 → IDENTIFY → 切断 を順次実行。
    // ただし既に識別済み (id でキャッシュ) のデバイスは再接続しない (上記
    // _identityCache の説明参照)。
    for (final dev in devices) {
      final cached = _identityCache[dev.id];
      if (cached != null) {
        dev.identity = cached;
        continue;
      }
      // クールダウン中 (直近の識別が連続失敗) のデバイスは今回はスキップ
      final cooldown = _identifyCooldown[dev.id];
      if (cooldown != null && DateTime.now().isBefore(cooldown.until)) {
        continue;
      }
      // identifyDevice 内部で IDENTIFY を複数回リトライする。それでも BLE は
      // 初回接続でサービス探索/notify 購読 (+ Windows はペアリング) が間に合わず、
      // 1 接続セッション内のリトライ窓では取りこぼすことがある (= 初回スキャンで
      // 「非対応」、再スキャンで成功、という症状)。これは「接続からやり直す」と
      // 直る (新規接続では OS が探索結果をキャッシュ済みで素早く整う) ため、
      // BLE は失敗時に接続ごとやり直す (手動再スキャンの自動化)。USB は従来どおり 1 回。
      final connectAttempts = dev.isBle ? 2 : 1;
      for (int i = 0; i < connectAttempts && dev.identity == null; i++) {
        final ok = await _midi.connect(dev);
        if (!ok) continue;
        try {
          dev.identity = await _midi.identifyDevice();
        } catch (_) {
          // 識別失敗は無視 (Mimic X 以外のデバイスかも)
        }
        _midi.disconnect();
        if (dev.identity == null && i < connectAttempts - 1) {
          await Future.delayed(const Duration(milliseconds: 400));
        }
      }
      // 識別できたものだけキャッシュ。失敗したデバイスはクールダウンを
      // 積み増して、しばらく再試行しない (時間経過で自動的に再試行される)。
      if (dev.identity != null) {
        _identityCache[dev.id] = dev.identity!;
        _identifyCooldown.remove(dev.id);
      } else {
        final fails = (cooldown?.fails ?? 0) + 1;
        final waitSecs = fails < 2 ? 0 : (15 << (fails - 2)).clamp(15, 120);
        _identifyCooldown[dev.id] = (
          fails: fails,
          until: DateTime.now().add(Duration(seconds: waitSecs)),
        );
      }
    }

    // serial 単位のニックネームを SharedPreferences からロード
    _nicknames.clear();
    for (final dev in devices) {
      final serial = dev.identity?.serial ?? '';
      if (serial.isEmpty) continue;
      final nick = await DeviceNicknameStore.get(serial);
      if (nick != null) _nicknames[serial] = nick;
    }

    if (mounted) {
      setState(() {
        _devices = devices;
        _scanning = false;
      });
    }
  }

  /// ニックネームがあればそれ、無ければ USB の iManufacturer + iProduct 名。
  String _displayNameFor(MidiDeviceInfo dev) {
    final serial = dev.identity?.serial ?? '';
    final nick = _nicknames[serial];
    if (nick != null && nick.isNotEmpty) return nick;
    return dev.name;
  }

  Future<void> _openRename(MidiDeviceInfo dev) async {
    final serial = dev.identity?.serial ?? '';
    if (serial.isEmpty) return;
    final current = _nicknames[serial] ?? '';
    // 画面を開く前に scan 用接続が残っていないこと (= disconnect 済み) を期待する。
    // rename 画面側で connect する。
    final result = await Navigator.of(context).push<String?>(
      MaterialPageRoute(
        builder: (_) => DeviceRenamePage(
          deviceInfo: dev,
          initialNickname: current,
          midi: _midi,
        ),
      ),
    );
    if (!mounted) return;
    // 'CONN_LOST' は HB 失敗で自動 pop されたケース。再 scan を促す。
    if (result == 'CONN_LOST') {
      final l = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.connectionLost)),
      );
      setState(() => _devices = []);
      await _scanAndIdentify();
      return;
    }
    // result は保存された文字列。null は ESC 等で破棄された場合。
    if (result == null) return;
    setState(() {
      if (result.isEmpty) {
        _nicknames.remove(serial);
      } else {
        _nicknames[serial] = result;
      }
    });
  }

  Future<void> _openDevice(MidiDeviceInfo device) async {
    if (_opening) return;
    setState(() => _opening = true);
    bool success = false;
    try {
      // 接続 → 生存確認 (probe)。Android は接続直後の write 詰まり (midi_service の
      // probeConnection コメント参照) を引くことがあり、その接続は identity が
      // キャッシュ済みだと無検査でセッションに入って HB 全滅 → 即 CONN_LOST になる。
      // probe が無応答なら接続からやり直す。
      for (int i = 0; i < 3 && mounted; i++) {
        success = await _midi.connect(device);
        if (!success) continue;
        if (await _midi.probeConnection()) break;
        _midi.disconnect();
        success = false;
        await Future.delayed(const Duration(milliseconds: 300));
      }
      if (success && mounted) {
        // 既存の identity がなければ識別を試みる
        device.identity ??= await _midi.identifyDevice();
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
    if (!success) {
      // Windows の BLE は、アダプタ側がボンド (LTK) を失っている (erase 付き
      // ファーム更新後など) と接続直後の切断を繰り返す。fork 側の自動修復
      // (unpair → 再ペアリング) でも復旧できずここまで落ちてきた場合の
      // 最終フォールバックとして、手動での復旧手順を案内する。
      if (mounted && device.isBle && Platform.isWindows) {
        final l = AppLocalizations.of(context)!;
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(l.bleWinPairingHintTitle),
            content: Text(l.bleWinPairingHintBody),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
      // 接続に失敗したら一覧を再読み込みする。電源 OFF などで消えたデバイスは
      // プラグイン側で既に除去済みなので、これで UI からも消える (手動リロード不要)。
      // まだ生きていれば再スキャンで残るので実害はない。
      if (mounted) await _scanAndIdentify();
      return;
    }
    if (!mounted) return;

    final identity = device.identity;
    final l = AppLocalizations.of(context)!;
    if (identity == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.deviceNotResponding)),
      );
      _midi.disconnect();
      return;
    }

    // 最低プロトコルバージョンチェック (v0.5.0 以降必須)
    if (!MinSupportedProtocol.meets(
        identity.protocolMajor, identity.protocolMinor)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.protocolTooOld(
          identity.protocolVersion,
          MinSupportedProtocol.label,
        ))),
      );
      _midi.disconnect();
      return;
    }

    // ファームのプロトコルがアプリ知識より新しい場合は警告 (続行は可能)
    if (MinSupportedProtocol.isNewerThanKnown(
        identity.protocolMajor, identity.protocolMinor)) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.protocolNewerWarningTitle),
          content: Text(l.protocolNewerWarningBody(
            identity.protocolVersion,
            MinSupportedProtocol.knownLatestLabel,
          )),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
      if (!mounted) return;
    }

    if (identity.channels.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.noChannelsAvailable)),
      );
      _midi.disconnect();
      return;
    }

    // X68000 の keyboard と mouse は 1 つの "X68000 キーボード (トラックパッド付き)"
    // 画面に同居するため、ピッカーでは 1 項目に集約する。
    // 例: combined ボード (joystick + x68k_kb + x68k_mouse の 3ch) では
    //     ピッカーは Joystick / X68000 Keyboard の 2 択になる。
    final x68kKb = identity.channels
        .cast<ChannelAssignment?>()
        .firstWhere(
          (c) => c!.hidType == HidType.keyboard && c.targetSystem == TargetSystem.x68000,
          orElse: () => null,
        );
    final x68kMouse = identity.channels
        .cast<ChannelAssignment?>()
        .firstWhere(
          (c) => c!.hidType == HidType.mouse && c.targetSystem == TargetSystem.x68000,
          orElse: () => null,
        );
    final hasX68kCombo = x68kKb != null && x68kMouse != null;

    final pickerChannels = identity.channels.where((c) {
      // x68k mouse は kb と同居している場合は kb 側の画面に統合されるので、
      // ピッカーには出さない。
      if (hasX68kCombo &&
          c.hidType == HidType.mouse &&
          c.targetSystem == TargetSystem.x68000) {
        return false;
      }
      return true;
    }).toList();

    // Combined デバイス (joystick + x68k キーボード/マウス) はチャンネル排他
    // 選択ではなく同時セッションで開く。ジョイスティック/キーボード両機能が
    // 常時アクティブで、AppBar のボタンで画面を行き来できる。
    final joyCh = pickerChannels.cast<ChannelAssignment?>().firstWhere(
          (c) => c!.hidType == HidType.joystick,
          orElse: () => null,
        );
    if (hasX68kCombo && joyCh != null) {
      _runCombinedSession(device, joyCh, x68kKb, x68kMouse);
      return;
    }

    if (pickerChannels.length == 1) {
      _routeToChannel(device, pickerChannels.first);
    } else {
      _showChannelPicker(device, pickerChannels);
    }
  }

  /// Combined デバイスの同時セッション。キーボード⇄ジョイスティック画面を
  /// AppBar のボタンで行き来し (pop result 'SWITCH_*')、その間 MIDI 接続は
  /// 維持される。最後に表示していた画面を記憶して次回の初期画面にする。
  void _runCombinedSession(
    MidiDeviceInfo device,
    ChannelAssignment joyCh,
    ChannelAssignment kbCh,
    ChannelAssignment mouseCh,
  ) async {
    final deviceName = _displayNameFor(device);
    final prefs = await SharedPreferences.getInstance();
    var screen = prefs.getString('combined.lastScreen') ?? 'keyboard';

    String? popResult;
    while (true) {
      final Widget page;
      if (screen == 'joystick') {
        page = JoystickPage(
          midi: _midi,
          channel: joyCh.midiChannel,
          deviceName: deviceName,
          onSwitchToKeyboard: () =>
              Navigator.of(context).pop('SWITCH_KEYBOARD'),
        );
      } else {
        page = X68kKeyboardPage(
          midi: _midi,
          channel: kbCh.midiChannel,
          mouseChannel: mouseCh.midiChannel,
          deviceName: deviceName,
          serial: device.identity?.serial,
          enableGamepad: true,
          onSwitchToJoystick: () =>
              Navigator.of(context).pop('SWITCH_JOYSTICK'),
        );
      }
      if (!mounted) return;
      popResult = await Navigator.of(context)
          .push<String?>(MaterialPageRoute(builder: (_) => page));
      if (popResult == 'SWITCH_KEYBOARD') {
        screen = 'keyboard';
      } else if (popResult == 'SWITCH_JOYSTICK') {
        screen = 'joystick';
      } else {
        break; // 戻る or CONN_LOST → セッション終了
      }
      await prefs.setString('combined.lastScreen', screen);
    }
    await _finishSession(popResult);
  }

  void _routeToChannel(MidiDeviceInfo device, ChannelAssignment ch) async {
    Widget? page;
    final deviceName = _displayNameFor(device);
    if (ch.hidType == HidType.joystick) {
      page = JoystickPage(
        midi: _midi,
        channel: ch.midiChannel,
        deviceName: deviceName,
      );
    } else if (ch.hidType == HidType.keyboard && ch.targetSystem == TargetSystem.x68000) {
      // 同じデバイスに X68000 マウスもあれば mouseChannel を渡してトラックパッド表示
      final mouseCh = device.identity?.channels
          .cast<ChannelAssignment?>()
          .firstWhere(
            (c) => c!.hidType == HidType.mouse && c.targetSystem == TargetSystem.x68000,
            orElse: () => null,
          );
      page = X68kKeyboardPage(
        midi: _midi,
        channel: ch.midiChannel,
        mouseChannel: mouseCh?.midiChannel,
        deviceName: deviceName,
        serial: device.identity?.serial,
      );
    }

    if (page == null) {
      final l = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.unsupportedFunction(ch.hidTypeLabel, ch.targetLabel))),
      );
      _midi.disconnect();
      return;
    }

    // 操作画面は HB 失敗時に 'CONN_LOST' を pop result で返す。
    final popResult =
        await Navigator.of(context).push<String?>(MaterialPageRoute(builder: (_) => page!));
    await _finishSession(popResult);
  }

  /// 操作画面から戻った後の共通後処理。
  /// Navigator.pop の Future はページ dispose より早く解決されるので、page 内で
  /// sendDisconnect しても USB が先に閉じてしまう (= デバイスに届かない)。
  /// ここで明示的に「HB 停止 → DISCONNECT 送信 → TX フラッシュ → USB close」する。
  Future<void> _finishSession(String? popResult) async {
    _midi.stopHeartBeat();
    _midi.sendDisconnect();
    await Future.delayed(const Duration(milliseconds: 100));
    _midi.disconnect();
    OrientationHelper.unlock();
    if (popResult == 'CONN_LOST' && mounted) {
      final l = AppLocalizations.of(context)!;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.connectionLost)),
      );
      // 一覧をクリアして再 scan
      setState(() => _devices = []);
      await _scanAndIdentify();
    }
  }

  void _showChannelPicker(
    MidiDeviceInfo device,
    List<ChannelAssignment> channels,
  ) {
    final l = AppLocalizations.of(context)!;
    showModalBottomSheet(
      context: context,
      // 横画面では bottom sheet の高さが狭く、ListTile 数によっては
      // overflow するので SingleChildScrollView で逃がす。
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(l.selectFunction, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              for (final ch in channels)
                ListTile(
                  leading: Icon(_iconForType(ch.hidType)),
                  title: Text(ch.hidTypeLabel),
                  subtitle: Text(l.homeChannelLabel(ch.midiChannel + 1, ch.targetLabel)),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _routeToChannel(device, ch);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _iconForType(int hidType) {
    switch (hidType) {
      case HidType.keyboard: return Icons.keyboard;
      case HidType.joystick: return Icons.gamepad;
      case HidType.mouse: return Icons.mouse;
      default: return Icons.device_unknown;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l.appTitle),
        actions: [
          IconButton(
            icon: _scanning
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            tooltip: l.homeRescanTooltip,
            onPressed: _scanning ? null : _scanAndIdentify,
          ),
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: l.homeAboutTooltip,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const AboutPage()),
            ),
          ),
        ],
      ),
      // 横画面ではカメラノッチ / ジェスチャ領域が左右に来るので SafeArea で
      // 避ける (portrait では AppBar が上を、ホームバーが下を吸収するので影響なし)
      body: SafeArea(
        child: Stack(
          children: [
            _buildBody(l),
            if (_opening)
              Positioned.fill(
                child: ColoredBox(
                  color: Colors.black54,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          l.homeConnecting,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(AppLocalizations l) {
    return _devices.isEmpty
          ? Center(
              child: _scanning
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(l.homeSearching),
                      ],
                    )
                  : Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        '${l.homeNoDevicesTitle}\n\n${l.homeNoDevicesHint}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey),
                      ),
                    ),
            )
          : ListView.builder(
              itemCount: _devices.length,
              itemBuilder: (context, index) {
                final device = _devices[index];
                final identity = device.identity;
                final isMimicX = identity != null;
                final hasSerial = (identity?.serial.isNotEmpty ?? false);
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: InkWell(
                    onTap: isMimicX ? () => _openDevice(device) : null,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Icon(
                            isMimicX
                                ? Icons.check_circle
                                : (device.isBle ? Icons.bluetooth : Icons.usb),
                            color: isMimicX ? Colors.green : Colors.grey,
                            size: 32,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // トランスポートバッジ: 同一実機が USB / BLE の両経路で
                                // 2 枚並んだとき (S3 ブリッジ等) の見分け用
                                Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        _displayNameFor(device),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Icon(
                                      device.isBle ? Icons.bluetooth : Icons.usb,
                                      size: 16,
                                      color: Colors.grey,
                                    ),
                                  ],
                                ),
                                if (identity != null) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    l.homeFirmwareVersion(
                                      identity.firmwareVersion,
                                      identity.protocolVersion,
                                    ),
                                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                                  ),
                                  const SizedBox(height: 4),
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 2,
                                    children: identity.channels
                                        .map((ch) => Chip(
                                              label: Text(
                                                '${ch.hidTypeLabel}/${ch.targetLabel}',
                                                style: const TextStyle(fontSize: 11),
                                              ),
                                              padding: EdgeInsets.zero,
                                              materialTapTargetSize:
                                                  MaterialTapTargetSize.shrinkWrap,
                                            ))
                                        .toList(),
                                  ),
                                ] else ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    l.homeIncompatibleNote,
                                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (hasSerial)
                            IconButton(
                              icon: const Icon(Icons.edit_outlined),
                              tooltip: l.deviceRenameTooltip,
                              onPressed: () => _openRename(device),
                            ),
                          if (isMimicX) const Icon(Icons.chevron_right),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
  }
}
