// ===================================================================================
// Combined デバイス (joystick + X68000 keyboard + mouse を 1 台で持つ) の同時セッション。
//
// キーボード画面とジョイスティック画面を **両方 IndexedStack に同時生存** させ、
// index を切り替えて瞬時に表示を入れ替える (旧実装は Navigator の push/pop で毎回
// dispose/再 init し、その間ハートビートが途切れてファーム LED が WAITING に落ちる
// 問題があった)。両画面が生きているので:
//   - ゲームパッドは JoystickPage の現行モードのバインダ 1 経路で常時駆動され、
//     キーボード表示中でも効く (キーボード側にゲームパッド実装を複製しない)。
//   - ハートビートはこのホストが 1 本だけ所有する (切替で途切れない)。
//
// 前面 (表示中) の 1 画面だけが画面の向き・IME・物理キーボード送信を制御するよう、
// 各ページには active フラグを渡す (ExcludeFocus で非表示ページの focus/IME 奪取も封じる)。
// ===================================================================================

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'joystick_page.dart';
import 'midi_service.dart';
import 'x68k_keyboard_page.dart';

class CombinedSessionPage extends StatefulWidget {
  final MidiService midi;
  final int joystickChannel;
  final int keyboardChannel;
  final int mouseChannel;
  final String? deviceName;
  final String? serial;

  const CombinedSessionPage({
    super.key,
    required this.midi,
    required this.joystickChannel,
    required this.keyboardChannel,
    required this.mouseChannel,
    this.deviceName,
    this.serial,
  });

  @override
  State<CombinedSessionPage> createState() => _CombinedSessionPageState();
}

class _CombinedSessionPageState extends State<CombinedSessionPage> {
  // 0 = keyboard, 1 = joystick
  int _screen = 0;
  bool _restored = false;

  @override
  void initState() {
    super.initState();
    _restoreLastScreen();
    // ハートビートはホストが 1 本所有する。画面切替でページを dispose/再 init しても
    // 途切れないので、ファーム側 LED が WAITING (オレンジ) に落ちない。
    // 3 秒応答が無ければ 'CONN_LOST' で pop し、HomePage 側が再 scan する。
    widget.midi.startHeartBeat(onFailure: _onHeartBeatFailure);
  }

  Future<void> _restoreLastScreen() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString('combined.lastScreen') ?? 'keyboard';
    if (mounted) {
      setState(() {
        _screen = last == 'joystick' ? 1 : 0;
        _restored = true;
      });
    }
  }

  void _onHeartBeatFailure() {
    if (!mounted) return;
    Navigator.of(context).pop('CONN_LOST');
  }

  Future<void> _setScreen(int screen) async {
    if (_screen == screen) return;
    setState(() => _screen = screen);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'combined.lastScreen', screen == 1 ? 'joystick' : 'keyboard');
  }

  @override
  Widget build(BuildContext context) {
    // 復元完了まで初期画面をちらつかせない。
    if (!_restored) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    final keyboardActive = _screen == 0;
    final joystickActive = _screen == 1;
    // 各ページは自前の ModeScaffold(=Scaffold, AppBar) を持つので、ホストは
    // Scaffold を持たず IndexedStack で並べるだけ (AppBar 移設の大改修を避ける)。
    // 非表示ページは ExcludeFocus で focus/IME を掴めないようにする
    // (LineInput の autofocus TextField が背面のまま IME を出すのを防ぐ)。
    return IndexedStack(
      index: _screen,
      children: [
        ExcludeFocus(
          excluding: !keyboardActive,
          child: X68kKeyboardPage(
            midi: widget.midi,
            channel: widget.keyboardChannel,
            mouseChannel: widget.mouseChannel,
            deviceName: widget.deviceName,
            serial: widget.serial,
            active: keyboardActive,
            manageHeartBeat: false,
            onSwitchToJoystick: () => _setScreen(1),
          ),
        ),
        ExcludeFocus(
          excluding: !joystickActive,
          child: JoystickPage(
            midi: widget.midi,
            channel: widget.joystickChannel,
            deviceName: widget.deviceName,
            active: joystickActive,
            manageHeartBeat: false,
            onSwitchToKeyboard: () => _setScreen(0),
          ),
        ),
      ],
    );
  }
}
