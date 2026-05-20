import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'about_page.dart';
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

class _HomePageState extends State<HomePage> {
  final MidiService _midi = MidiService();
  List<MidiDeviceInfo> _devices = [];
  bool _scanning = false;

  @override
  void initState() {
    super.initState();
    // ホーム画面は OS の自動回転に追従させる (横持ち利用も多いため固定しない)。
    OrientationHelper.unlock();

    _midi.onDisconnect = () {
      if (mounted) setState(() {});
    };
    // 起動時に自動スキャン
    Future.microtask(_scanAndIdentify);
  }

  @override
  void dispose() {
    _midi.dispose();
    super.dispose();
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

    if (mounted) {
      setState(() {
        _devices = devices;
        _scanning = false;
      });
    }
  }

  Future<void> _openDevice(MidiDeviceInfo device) async {
    final success = await _midi.connect(device);
    if (!success || !mounted) return;

    // 既存の identity がなければ識別を試みる
    device.identity ??= await _midi.identifyDevice();
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

    if (pickerChannels.length == 1) {
      _routeToChannel(device, pickerChannels.first);
    } else {
      _showChannelPicker(device, pickerChannels);
    }
  }

  void _routeToChannel(MidiDeviceInfo device, ChannelAssignment ch) async {
    Widget? page;
    if (ch.hidType == HidType.joystick) {
      page = JoystickPage(midi: _midi, channel: ch.midiChannel);
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

    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page!));
    // 戻ってきたら切断 + 回転ロック解除 (ホーム画面は OS の自動回転に追従)
    _midi.disconnect();
    OrientationHelper.unlock();
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
        child: _devices.isEmpty
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
                                  device.name,
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
                          if (isMimicX) const Icon(Icons.chevron_right),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
      ),
    );
  }
}
