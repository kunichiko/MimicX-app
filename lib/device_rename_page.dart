// ===================================================================================
// device_rename_page.dart
// ===================================================================================
// アダプタ個体のニックネーム編集画面。
//
// 入場時:
//   1) 対象アダプタに接続
//   2) IDENTIFY (アダプタ側状態を SCANNED に遷移)
//   3) HEART_BEAT 開始 (1 秒間隔)。アダプタは CONNECTED に遷移
//   4) LED を赤 (override) + Slow 点滅 にして「編集中」を明示
//
// 離場時:
//   1) HEART_BEAT 停止
//   2) DISCONNECT (0x09) を送る → アダプタは即座に SCANNED (緑) に戻り override クリア
//   3) USB TX フラッシュのため 100ms 待機してから接続を切る
//
// HEART_BEAT 3 連続失敗 (~3 秒):
//   接続不能と判断し画面 pop。HomePage 側で再 scan される。
//
// 保存ロジック:
//   入力文字列を trim して空なら nickname 削除 (デバイス名にフォールバック)。
//   max 50 文字制限は TextField の maxLength で UI 側強制。
// ===================================================================================

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'device_nickname_store.dart';
import 'l10n/app_localizations.dart';
import 'midi_service.dart';
import 'protocol.dart';

class DeviceRenamePage extends StatefulWidget {
  final MidiDeviceInfo deviceInfo;
  final String initialNickname;
  final MidiService midi;

  const DeviceRenamePage({
    super.key,
    required this.deviceInfo,
    required this.initialNickname,
    required this.midi,
  });

  @override
  State<DeviceRenamePage> createState() => _DeviceRenamePageState();
}

class _DeviceRenamePageState extends State<DeviceRenamePage> {
  static const int _maxNicknameLength = 50;

  late final TextEditingController _controller;
  bool _connecting = true;
  bool _connectFailed = false;
  /// HB 失敗で自動 pop する際の戻り値。null は通常 (= 編集破棄), 'CONN_LOST' は失敗。
  String? _autoPopResult;

  String get _serial => widget.deviceInfo.identity?.serial ?? '';

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialNickname);
    Future.microtask(_enterEditingState);
  }

  Future<void> _enterEditingState() async {
    final ok = await widget.midi.connect(widget.deviceInfo);
    if (!mounted) return;
    if (!ok) {
      setState(() {
        _connecting = false;
        _connectFailed = true;
      });
      return;
    }
    // ファームに IDENTIFY を撃って "SCANNED" 状態 (緑) に持って行く。
    await widget.midi.identifyDevice();
    if (!mounted) return;
    // HB 開始 → ファームは CONNECTED に遷移する。失敗時は画面を畳む。
    widget.midi.startHeartBeat(onFailure: _onHeartBeatFailure);
    // LED override: 赤 Slow 点滅
    widget.midi.setLedColor(255, 0, 0);
    widget.midi.setLedBlink(LedBlinkSpeed.slow);
    setState(() => _connecting = false);
  }

  void _onHeartBeatFailure() {
    if (!mounted) return;
    _autoPopResult = 'CONN_LOST';
    Navigator.of(context).pop(_autoPopResult);
  }

  Future<void> _leaveEditingState() async {
    // HB を止めてから DISCONNECT を送る。順序を逆にすると HB tick が走って
    // CONNECTED に戻ってしまう。DISCONNECT は override も内部でクリアするので
    // 別途 resetLedOverride を送る必要はない。
    widget.midi.stopHeartBeat();
    widget.midi.sendDisconnect();
    // USB TX キューがケーブルに乗るまで待ってから USB を閉じる。
    await Future.delayed(const Duration(milliseconds: 100));
    widget.midi.disconnect();
  }

  @override
  void dispose() {
    _controller.dispose();
    _leaveEditingState();  // fire-and-forget (dispose は await できない)
    super.dispose();
  }

  Future<void> _save() async {
    final value = _controller.text.trim();
    await DeviceNicknameStore.set(_serial, value);
    if (!mounted) return;
    Navigator.of(context).pop(value);
  }

  Future<void> _clear() async {
    await DeviceNicknameStore.delete(_serial);
    if (!mounted) return;
    Navigator.of(context).pop('');
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l.deviceRenameTitle)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l.deviceRenameSerialLabel(_serial),
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 16),
              if (_connecting)
                Row(
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Text(l.deviceRenameConnecting),
                  ],
                )
              else if (_connectFailed)
                Text(
                  l.deviceRenameConnectFailed,
                  style: const TextStyle(color: Colors.redAccent),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: _controller,
                enabled: !_connecting,
                maxLength: _maxNicknameLength,
                inputFormatters: [
                  LengthLimitingTextInputFormatter(_maxNicknameLength),
                ],
                decoration: InputDecoration(
                  labelText: l.deviceRenameHint,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _connecting ? null : _clear,
                      icon: const Icon(Icons.restore),
                      label: Text(l.deviceRenameClearButton),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _connecting ? null : _save,
                      icon: const Icon(Icons.check),
                      label: Text(l.deviceRenameSaveButton),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
