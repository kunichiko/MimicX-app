import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'about_page.dart';
import 'device_nickname_store.dart';
import 'device_rename_page.dart';
import 'l10n/app_localizations.dart';
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
    final devices = await _midi.scanDevices();

    // 各デバイスに対して接続 → IDENTIFY → 切断 を順次実行
    for (final dev in devices) {
      final ok = await _midi.connect(dev);
      if (!ok) continue;
      try {
        // identifyDevice 内部で複数回リトライするので呼び出し側は 1 回でよい。
        // 過去には macOS の connectToDevice が CoreMIDI ポート open 完了前に返り
        // 初回 IDENTIFY を取りこぼす問題、Android で app を一度落としてから
        // 再接続したときに 1 回目が間に合わない問題があり、いずれも
        // identifyDevice の内部リトライで吸収する。
        dev.identity = await _midi.identifyDevice();
      } catch (_) {
        // 識別失敗は無視 (Mimic X 以外のデバイスかも)
      }
      _midi.disconnect();
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
    bool success;
    try {
      success = await _midi.connect(device);
      if (success && mounted) {
        // 既存の identity がなければ識別を試みる
        device.identity ??= await _midi.identifyDevice();
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
    if (!success || !mounted) return;

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

    if (pickerChannels.length == 1) {
      _routeToChannel(device, pickerChannels.first);
    } else {
      _showChannelPicker(device, pickerChannels);
    }
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
    // Navigator.pop の Future はページ dispose より早く解決されるので、page 内で
    // sendDisconnect しても USB が先に閉じてしまう (= デバイスに届かない)。
    // ここで明示的に「HB 停止 → DISCONNECT 送信 → TX フラッシュ → USB close」する。
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
                            isMimicX ? Icons.check_circle : Icons.usb,
                            color: isMimicX ? Colors.green : Colors.grey,
                            size: 32,
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _displayNameFor(device),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
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
