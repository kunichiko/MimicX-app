import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'channel_mode.dart';
import 'l10n/app_localizations.dart';
import 'midi_service.dart';
import 'mode_scaffold.dart';
import 'joystick_settings.dart';
import 'orientation_helper.dart';
import 'protocol.dart';

// ===========================================================================
// JoystickPage 本体
// 横向き固定 + 複数モード (ATARI / MD6 / 将来追加) を ModeScaffold で切り替え。
// ===========================================================================

class JoystickPage extends StatefulWidget {
  final MidiService midi;
  final int channel;

  const JoystickPage({
    super.key,
    required this.midi,
    this.channel = MidiService.chJoystickDefault,
  });

  @override
  State<JoystickPage> createState() => _JoystickPageState();
}

class _JoystickPageState extends State<JoystickPage> {
  late final List<ChannelMode> _modes;

  @override
  void initState() {
    super.initState();
    // 横向き固定 (Android では auto-rotate ロックを無視して両方向許容)
    OrientationHelper.landscape();
    _modes = [
      AtariMode(channel: widget.channel),
      Md6Mode(channel: widget.channel),
      LibbleRabbleMode(channel: widget.channel),
    ];
  }

  @override
  void dispose() {
    for (final m in _modes) {
      m.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    return ModeScaffold(
      title: l.joystickTitle,
      midi: widget.midi,
      modes: _modes,
      persistenceKey: 'joystick.selectedMode',
    );
  }
}

// ===========================================================================
// 各モード
// ===========================================================================

/// ATARI 互換 2 ボタンモード。
class AtariMode extends ChannelMode {
  final int channel;
  final JoystickSettings _settings =
      JoystickSettings(prefix: 'joystick.atari');

  AtariMode({required this.channel}) {
    // 設定変更 (turbo の ON/OFF や load 完了) を本体 body へ反映するため
    // notifyListeners を中継する。これがないと ModeScaffold 側の
    // AnimatedBuilder が再ビルドされず、turbo の「連」バッジや
    // 連射タイマー起動が反映されない。
    _settings.addListener(notifyListeners);
  }

  /// このモードで連射対象になり得るボタン。
  static const List<({int note, String label})> _turboCandidates = [
    (note: MidiService.noteA, label: 'A'),
    (note: MidiService.noteB, label: 'B'),
  ];

  @override
  String get id => 'joystick.atari';

  @override
  String label(BuildContext context) =>
      AppLocalizations.of(context)!.padModeAtari;

  @override
  Future<String?> onEnter(MidiService midi) async {
    await _settings.load();
    final result = await midi.setPadMode(0);
    if (!result.isOk) return AckStatus.label(result.status);
    return null;
  }

  @override
  Widget buildBody(BuildContext context, MidiService midi) {
    return _LandscapeGate(child: _AtariLayout(midi: midi, settings: _settings));
  }

  @override
  Widget buildSettings(BuildContext context) =>
      _SettingsSheet(settings: _settings, turboCandidates: _turboCandidates);

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }
}

/// メガドライブ 6 ボタンパッド互換モード。
class Md6Mode extends ChannelMode {
  final int channel;
  final JoystickSettings _settings =
      JoystickSettings(prefix: 'joystick.md6');

  Md6Mode({required this.channel}) {
    _settings.addListener(notifyListeners);
  }

  static const List<({int note, String label})> _turboCandidates = [
    (note: MidiService.noteX, label: 'X'),
    (note: MidiService.noteY, label: 'Y'),
    (note: MidiService.noteZ, label: 'Z'),
    (note: MidiService.noteA, label: 'A'),
    (note: MidiService.noteB, label: 'B'),
    (note: MidiService.noteC, label: 'C'),
  ];

  @override
  String get id => 'joystick.md6';

  @override
  String label(BuildContext context) =>
      AppLocalizations.of(context)!.padModeMd6;

  @override
  Future<String?> onEnter(MidiService midi) async {
    await _settings.load();
    final result = await midi.setPadMode(1);
    if (!result.isOk) return AckStatus.label(result.status);
    return null;
  }

  @override
  Widget buildBody(BuildContext context, MidiService midi) {
    return _LandscapeGate(child: _Md6Layout(midi: midi, settings: _settings));
  }

  @override
  Widget buildSettings(BuildContext context) =>
      _SettingsSheet(settings: _settings, turboCandidates: _turboCandidates);

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }
}

/// リブルラブル (XPD-1LR) 互換モード。左右に十字キー、中央に A/B ボタン。
/// X68000 が PA0 (TH/COMMON) をトグルすることで左右レバー入力を時分割多重で
/// 読み取る。ファーム側 (PAD_MODE_LIBBLE_RABBLE = 2) が TH エッジに同期して
/// 左右レバー状態を D0-D3 に乗せ替える。
class LibbleRabbleMode extends ChannelMode {
  final int channel;
  final JoystickSettings _settings =
      JoystickSettings(prefix: 'joystick.libbleRabble');

  LibbleRabbleMode({required this.channel}) {
    _settings.addListener(notifyListeners);
  }

  static const List<({int note, String label})> _turboCandidates = [
    (note: MidiService.noteA, label: 'A'),
    (note: MidiService.noteB, label: 'B'),
  ];

  @override
  String get id => 'joystick.libbleRabble';

  @override
  String label(BuildContext context) =>
      AppLocalizations.of(context)!.padModeLibbleRabble;

  @override
  Future<String?> onEnter(MidiService midi) async {
    await _settings.load();
    final result = await midi.setPadMode(2);
    if (!result.isOk) return AckStatus.label(result.status);
    return null;
  }

  @override
  Widget buildBody(BuildContext context, MidiService midi) {
    return _LandscapeGate(
      child: _LibbleRabbleLayout(midi: midi, settings: _settings),
    );
  }

  @override
  Widget buildSettings(BuildContext context) =>
      _SettingsSheet(settings: _settings, turboCandidates: _turboCandidates);

  @override
  void dispose() {
    _settings.dispose();
    super.dispose();
  }
}

/// OS の回転がまだ完了していない過渡フレームでは portrait 幅でレイアウトが
/// 組まれて RenderFlex がオーバーフローするので、landscape になるまで描画を
/// 保留する。
class _LandscapeGate extends StatelessWidget {
  final Widget child;
  const _LandscapeGate({required this.child});

  @override
  Widget build(BuildContext context) {
    return OrientationBuilder(
      builder: (context, orientation) {
        if (orientation != Orientation.landscape) {
          return const SizedBox.expand();
        }
        return child;
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 方向キー (スライド対応 + 不感エリアを設定値で制御)
// ---------------------------------------------------------------------------

class _DPad extends StatefulWidget {
  final MidiService midi;
  final double deadZoneRatio;
  /// このパッドが送る note。デュアル D-pad のときは右側を別 note にする。
  final int noteUp;
  final int noteDown;
  final int noteLeft;
  final int noteRight;
  const _DPad({
    required this.midi,
    required this.deadZoneRatio,
    this.noteUp = MidiService.noteUp,
    this.noteDown = MidiService.noteDown,
    this.noteLeft = MidiService.noteLeft,
    this.noteRight = MidiService.noteRight,
  });

  @override
  State<_DPad> createState() => _DPadState();
}

class _DPadState extends State<_DPad> {
  bool _up = false, _down = false, _left = false, _right = false;

  /// 指が現在 dead zone (中央の不感領域) に入っているか。スクリーン上には
  /// 物理的な突起がないので、中央位置を触覚で示すために、外 → 中の遷移時
  /// (= 全方向 OFF に変わった瞬間と、最初に dead zone をタップした瞬間) に
  /// 軽い振動を返す。中 → 外への遷移は無音。
  bool _inDeadZone = false;

  void _updateDirection(Offset? localPos, double size) {
    if (localPos == null) {
      _setAll(false, false, false, false);
      _inDeadZone = false;  // 指が離れた → 次回の侵入で再度フィードバック
      return;
    }
    final center = size / 2;
    final dx = localPos.dx - center;
    final dy = localPos.dy - center;
    final deadZone = size * widget.deadZoneRatio;

    final newUp = dy < -deadZone;
    final newDown = dy > deadZone;
    final newLeft = dx < -deadZone;
    final newRight = dx > deadZone;

    final nowInDeadZone = !newUp && !newDown && !newLeft && !newRight;
    if (nowInDeadZone && !_inDeadZone) {
      HapticFeedback.lightImpact();
    }
    _inDeadZone = nowInDeadZone;

    _setAll(newUp, newDown, newLeft, newRight);
  }

  void _setAll(bool up, bool down, bool left, bool right) {
    if (up != _up) {
      _up = up;
      up ? widget.midi.joystickPress(widget.noteUp)
         : widget.midi.joystickRelease(widget.noteUp);
    }
    if (down != _down) {
      _down = down;
      down ? widget.midi.joystickPress(widget.noteDown)
           : widget.midi.joystickRelease(widget.noteDown);
    }
    if (left != _left) {
      _left = left;
      left ? widget.midi.joystickPress(widget.noteLeft)
           : widget.midi.joystickRelease(widget.noteLeft);
    }
    if (right != _right) {
      _right = right;
      right ? widget.midi.joystickPress(widget.noteRight)
            : widget.midi.joystickRelease(widget.noteRight);
    }
    setState(() {});
  }

  @override
  void dispose() {
    if (_up) widget.midi.joystickRelease(widget.noteUp);
    if (_down) widget.midi.joystickRelease(widget.noteDown);
    if (_left) widget.midi.joystickRelease(widget.noteLeft);
    if (_right) widget.midi.joystickRelease(widget.noteRight);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const size = 200.0;
    return GestureDetector(
      onPanStart: (d) => _updateDirection(d.localPosition, size),
      onPanUpdate: (d) => _updateDirection(d.localPosition, size),
      onPanEnd: (_) => _updateDirection(null, size),
      onPanCancel: () => _updateDirection(null, size),
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: Colors.grey.shade900,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Stack(
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: _DPadArrow(icon: Icons.arrow_drop_up, active: _up, width: 64, height: 60),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: _DPadArrow(icon: Icons.arrow_drop_down, active: _down, width: 64, height: 60),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: _DPadArrow(icon: Icons.arrow_left, active: _left, width: 60, height: 64),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: _DPadArrow(icon: Icons.arrow_right, active: _right, width: 60, height: 64),
            ),
          ],
        ),
      ),
    );
  }
}

class _DPadArrow extends StatelessWidget {
  final IconData icon;
  final bool active;
  final double width;
  final double height;

  const _DPadArrow({
    required this.icon,
    required this.active,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: active ? Colors.white24 : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(icon, size: 40, color: active ? Colors.white : Colors.grey),
    );
  }
}

// ---------------------------------------------------------------------------
// ボタングループ
//   - 1 つの Listener で全ポインタを追跡し、各ポインタ位置から各ボタンへの距離
//     で押下中ボタン集合を毎回算出する
//   - 各ボタンのヒット判定半径 = 視覚半径 + extraHitRadius (設定値)
//   - extraHitRadius を上げると隣接ボタンとオーバーラップして「指の腹で AB
//     同時押し」「A→AB境界→B のスライド遷移」が可能
// ---------------------------------------------------------------------------

class _ButtonSpec {
  final int note;
  final String label;
  final Color color;
  final double size;
  final Offset center;

  const _ButtonSpec({
    required this.note,
    required this.label,
    required this.color,
    required this.size,
    required this.center,
  });
}

class _ButtonGroup extends StatefulWidget {
  final MidiService midi;
  final List<_ButtonSpec> buttons;
  final Size groupSize;
  final double extraHitRadius;
  final Set<int> turboNotes;
  final double turboRate;

  const _ButtonGroup({
    required this.midi,
    required this.buttons,
    required this.groupSize,
    required this.extraHitRadius,
    required this.turboNotes,
    required this.turboRate,
  });

  @override
  State<_ButtonGroup> createState() => _ButtonGroupState();
}

class _ButtonGroupState extends State<_ButtonGroup> {
  final Map<int, Offset> _pointers = {};

  /// 指がボタン上に乗っている note 集合 (論理的に押下中)
  Set<int> _activeNotes = {};

  /// turbo モードの note の現在の物理状態 (true = press 中、false = release 中)。
  /// turbo 中 でかつ active な note のみエントリを持つ。
  final Map<int, bool> _turboPressed = {};

  Timer? _turboTimer;

  void _onPointerDown(PointerDownEvent e) {
    _pointers[e.pointer] = e.localPosition;
    _recompute();
  }

  void _onPointerMove(PointerMoveEvent e) {
    _pointers[e.pointer] = e.localPosition;
    _recompute();
  }

  void _onPointerUp(PointerUpEvent e) {
    _pointers.remove(e.pointer);
    _recompute();
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _pointers.remove(e.pointer);
    _recompute();
  }

  void _recompute() {
    final newActive = <int>{};
    for (final pos in _pointers.values) {
      for (final btn in widget.buttons) {
        final d = (pos - btn.center).distance;
        final hitR = btn.size / 2 + widget.extraHitRadius;
        if (d <= hitR) newActive.add(btn.note);
      }
    }

    final entered = newActive.difference(_activeNotes);
    final exited = _activeNotes.difference(newActive);

    // 新しく押下されたボタンがあれば触覚フィードバック (1 フレームに何個入っても
    // 1 回だけ。turbo の連射 tick では鳴らさない)。
    if (entered.isNotEmpty) {
      HapticFeedback.lightImpact();
    }

    // 指が乗った: 即時 press。turbo 対象なら以降タイマーで toggle する。
    for (final note in entered) {
      widget.midi.joystickPress(note);
      if (widget.turboNotes.contains(note)) {
        _turboPressed[note] = true;
      }
    }
    // 指が離れた: 物理的に押下中なら release。
    for (final note in exited) {
      if (widget.turboNotes.contains(note)) {
        if (_turboPressed[note] == true) {
          widget.midi.joystickRelease(note);
        }
        _turboPressed.remove(note);
      } else {
        widget.midi.joystickRelease(note);
      }
    }

    if (entered.isNotEmpty || exited.isNotEmpty) {
      setState(() => _activeNotes = newActive);
    }

    _ensureTurboTimer();
  }

  void _ensureTurboTimer() {
    final hasActiveTurbo = _activeNotes.any(widget.turboNotes.contains);
    if (hasActiveTurbo && _turboTimer == null) {
      _startTurboTimer();
    } else if (!hasActiveTurbo && _turboTimer != null) {
      _stopTurboTimer();
    }
  }

  void _startTurboTimer() {
    // rate Hz = 1秒間の press 回数。1 cycle = press + release の 2 トグルなので、
    // タイマー間隔は 1000 / (2 * rate) ms。最低 16 ms (≈ 60 Hz upper bound) で
    // クランプして暴走を防ぐ。
    final periodMs = math.max(16, (1000 / (2 * widget.turboRate)).round());
    _turboTimer = Timer.periodic(
      Duration(milliseconds: periodMs),
      (_) => _onTurboTick(),
    );
  }

  void _stopTurboTimer() {
    _turboTimer?.cancel();
    _turboTimer = null;
  }

  void _onTurboTick() {
    for (final note in _activeNotes) {
      if (!widget.turboNotes.contains(note)) continue;
      final wasPressed = _turboPressed[note] ?? false;
      final nowPressed = !wasPressed;
      _turboPressed[note] = nowPressed;
      if (nowPressed) {
        widget.midi.joystickPress(note);
      } else {
        widget.midi.joystickRelease(note);
      }
    }
  }

  @override
  void didUpdateWidget(covariant _ButtonGroup oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 設定値 (extraHitRadius) やボタン定義が変わったら、現在のポインタ位置で
    // 押下中集合を再計算して即時反映する。
    if (oldWidget.extraHitRadius != widget.extraHitRadius ||
        oldWidget.buttons != widget.buttons) {
      _recompute();
    }

    // turbo 集合変化: アクティブな note の物理状態を破綻させないよう調整。
    if (!setEquals(oldWidget.turboNotes, widget.turboNotes)) {
      // turbo → 非 turbo に変わった note: もし release 半サイクルで止まって
      // いたら再 press して、指を離すまで押し続け状態にする。
      for (final note
          in oldWidget.turboNotes.difference(widget.turboNotes)) {
        if (_activeNotes.contains(note) && _turboPressed[note] != true) {
          widget.midi.joystickPress(note);
        }
        _turboPressed.remove(note);
      }
      // 非 turbo → turbo に変わった note: 既に press 中の状態から turbo
      // サイクルに入る。物理状態は press のままにし、タイマー起動。
      for (final note
          in widget.turboNotes.difference(oldWidget.turboNotes)) {
        if (_activeNotes.contains(note)) {
          _turboPressed[note] = true;
        }
      }
      _ensureTurboTimer();
    }

    // turbo レート変更: タイマー再起動。
    if (oldWidget.turboRate != widget.turboRate && _turboTimer != null) {
      _stopTurboTimer();
      _startTurboTimer();
    }
  }

  @override
  void dispose() {
    _stopTurboTimer();
    for (final note in _activeNotes) {
      if (widget.turboNotes.contains(note)) {
        if (_turboPressed[note] == true) {
          widget.midi.joystickRelease(note);
        }
      } else {
        widget.midi.joystickRelease(note);
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onPointerDown,
      onPointerMove: _onPointerMove,
      onPointerUp: _onPointerUp,
      onPointerCancel: _onPointerCancel,
      child: SizedBox(
        width: widget.groupSize.width,
        height: widget.groupSize.height,
        child: Stack(
          children: [
            for (final btn in widget.buttons)
              Positioned(
                left: btn.center.dx - btn.size / 2,
                top: btn.center.dy - btn.size / 2,
                child: IgnorePointer(
                  child: _ActionButtonView(
                    label: btn.label,
                    color: btn.color,
                    size: btn.size,
                    pressed: _activeNotes.contains(btn.note),
                    turbo: widget.turboNotes.contains(btn.note),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// ATARI レイアウト (A, B 横並び)
// ---------------------------------------------------------------------------

class _AtariLayout extends StatelessWidget {
  final MidiService midi;
  final JoystickSettings settings;
  const _AtariLayout({required this.midi, required this.settings});

  @override
  Widget build(BuildContext context) {
    const btnSize = 80.0;
    const gap = 24.0;
    const groupW = btnSize * 2 + gap;
    final buttons = [
      _ButtonSpec(
        note: MidiService.noteA, label: 'A', color: Colors.red,
        size: btnSize,
        center: const Offset(btnSize / 2, btnSize / 2),
      ),
      _ButtonSpec(
        note: MidiService.noteB, label: 'B', color: Colors.blue,
        size: btnSize,
        center: const Offset(btnSize + gap + btnSize / 2, btnSize / 2),
      ),
    ];

    return Center(
      child: FractionallySizedBox(
        widthFactor: 0.8,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _DPad(midi: midi, deadZoneRatio: settings.deadZoneRatio),
            _ButtonGroup(
              midi: midi,
              buttons: buttons,
              groupSize: const Size(groupW, btnSize),
              extraHitRadius: settings.extraHitRadius,
              turboNotes: settings.turboNotes,
              turboRate: settings.turboRate,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MD 6B レイアウト (X Y Z / A B C 6つを1グループ + Mode/Start 単独)
// ---------------------------------------------------------------------------

class _Md6Layout extends StatelessWidget {
  final MidiService midi;
  final JoystickSettings settings;
  const _Md6Layout({required this.midi, required this.settings});

  @override
  Widget build(BuildContext context) {
    const btnSize = 64.0;
    const gap = 12.0;
    const groupW = btnSize * 3 + gap * 2;
    const groupH = btnSize * 2 + gap;

    Offset cellCenter(int col, int row) => Offset(
      btnSize / 2 + col * (btnSize + gap),
      btnSize / 2 + row * (btnSize + gap),
    );

    final buttons = [
      _ButtonSpec(note: MidiService.noteX, label: 'X', color: Colors.purple, size: btnSize, center: cellCenter(0, 0)),
      _ButtonSpec(note: MidiService.noteY, label: 'Y', color: Colors.purple, size: btnSize, center: cellCenter(1, 0)),
      _ButtonSpec(note: MidiService.noteZ, label: 'Z', color: Colors.purple, size: btnSize, center: cellCenter(2, 0)),
      _ButtonSpec(note: MidiService.noteA, label: 'A', color: Colors.red,    size: btnSize, center: cellCenter(0, 1)),
      _ButtonSpec(note: MidiService.noteB, label: 'B', color: Colors.blue,   size: btnSize, center: cellCenter(1, 1)),
      _ButtonSpec(note: MidiService.noteC, label: 'C', color: Colors.green,  size: btnSize, center: cellCenter(2, 1)),
    ];

    // 横画面のノッチ / カメラ領域に Mode ボタン等が隠れるのを避けるため
    // Stack 全体を SafeArea で囲む。
    return SafeArea(
      child: Stack(
        children: [
          // Mode (右上、単独タップ)
          Positioned(
            top: 8,
            right: 16,
            child: _SingleButton(
              midi: midi, note: MidiService.noteMode, label: 'Mode',
              color: Colors.grey, size: 40, width: 72,
            ),
          ),
          // Start (中央、単独タップ)
          Align(
            alignment: Alignment.center,
            child: _SingleButton(
              midi: midi, note: MidiService.noteStart, label: 'Start',
              color: Colors.grey, size: 48, width: 88,
            ),
          ),
          // 十字キー + 6 ボタン
          Center(
            child: FractionallySizedBox(
              widthFactor: 0.85,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _DPad(midi: midi, deadZoneRatio: settings.deadZoneRatio),
                  _ButtonGroup(
                    midi: midi,
                    buttons: buttons,
                    groupSize: const Size(groupW, groupH),
                    extraHitRadius: settings.extraHitRadius,
                    turboNotes: settings.turboNotes,
                    turboRate: settings.turboRate,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// リブルラブル (XPD-1LR) レイアウト: 左 D-pad / 中央 A・B / 右 D-pad
// ---------------------------------------------------------------------------

class _LibbleRabbleLayout extends StatelessWidget {
  final MidiService midi;
  final JoystickSettings settings;
  const _LibbleRabbleLayout({required this.midi, required this.settings});

  @override
  Widget build(BuildContext context) {
    const btnSize = 72.0;
    const gap = 16.0;
    const groupW = btnSize * 2 + gap;
    final centerButtons = [
      _ButtonSpec(
        note: MidiService.noteA, label: 'A', color: Colors.red,
        size: btnSize,
        center: const Offset(btnSize / 2, btnSize / 2),
      ),
      _ButtonSpec(
        note: MidiService.noteB, label: 'B', color: Colors.blue,
        size: btnSize,
        center: const Offset(btnSize + gap + btnSize / 2, btnSize / 2),
      ),
    ];

    return SafeArea(
      child: Center(
        child: FractionallySizedBox(
          widthFactor: 0.95,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _DPad(
                midi: midi,
                deadZoneRatio: settings.deadZoneRatio,
                // 左 D-pad はデフォルト note (1-4)
              ),
              _ButtonGroup(
                midi: midi,
                buttons: centerButtons,
                groupSize: const Size(groupW, btnSize),
                extraHitRadius: settings.extraHitRadius,
                turboNotes: settings.turboNotes,
                turboRate: settings.turboRate,
              ),
              _DPad(
                midi: midi,
                deadZoneRatio: settings.deadZoneRatio,
                noteUp: MidiService.noteUp2,
                noteDown: MidiService.noteDown2,
                noteLeft: MidiService.noteLeft2,
                noteRight: MidiService.noteRight2,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 視覚専用ボタン (押下状態は親から bool で渡される)
// ---------------------------------------------------------------------------

class _ActionButtonView extends StatelessWidget {
  final String label;
  final Color color;
  final double size;
  final double? width;
  final bool pressed;
  final bool turbo;

  const _ActionButtonView({
    required this.label,
    required this.color,
    required this.size,
    this.width,
    required this.pressed,
    this.turbo = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width ?? size,
      height: size,
      decoration: BoxDecoration(
        color: pressed ? color.withValues(alpha: 0.9) : color.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(size > 60 ? 12 : 8),
        border: Border.all(
          color: pressed ? Colors.white : Colors.grey,
          width: pressed ? 3 : 1,
        ),
      ),
      child: Stack(
        children: [
          Center(
            child: Text(
              label,
              style: TextStyle(
                fontSize: size > 60 ? 22 : 14,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          if (turbo)
            Positioned(
              top: 2,
              right: 4,
              child: Text(
                AppLocalizations.of(context)!.turboBadge,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: Colors.amberAccent,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 単独タップボタン (Mode / Start 用、オーバーラップ対象外)
// ---------------------------------------------------------------------------

class _SingleButton extends StatefulWidget {
  final MidiService midi;
  final int note;
  final String label;
  final Color color;
  final double size;
  final double? width;

  const _SingleButton({
    required this.midi,
    required this.note,
    required this.label,
    required this.color,
    required this.size,
    this.width,
  });

  @override
  State<_SingleButton> createState() => _SingleButtonState();
}

class _SingleButtonState extends State<_SingleButton> {
  bool _pressed = false;

  void _press() {
    if (_pressed) return;
    setState(() => _pressed = true);
    widget.midi.joystickPress(widget.note);
  }

  void _release() {
    if (!_pressed) return;
    setState(() => _pressed = false);
    widget.midi.joystickRelease(widget.note);
  }

  @override
  void dispose() {
    if (_pressed) widget.midi.joystickRelease(widget.note);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _press(),
      onTapUp: (_) => _release(),
      onTapCancel: () => _release(),
      child: _ActionButtonView(
        label: widget.label,
        color: widget.color,
        size: widget.size,
        width: widget.width,
        pressed: _pressed,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 設定シート (歯車アイコンから開く)
// ---------------------------------------------------------------------------

class _SettingsSheet extends StatefulWidget {
  final JoystickSettings settings;
  /// このモードで連射対象になり得るボタン (FilterChip の表示順)。
  final List<({int note, String label})> turboCandidates;

  const _SettingsSheet({
    required this.settings,
    required this.turboCandidates,
  });

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late double _deadZone;
  late double _extraHit;
  late double _turboRate;

  @override
  void initState() {
    super.initState();
    _deadZone = widget.settings.deadZoneRatio;
    _extraHit = widget.settings.extraHitRadius;
    _turboRate = widget.settings.turboRate;
    widget.settings.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    // turbo の chip 切り替えなどで再描画する。slider の値はローカル state を
    // 正にしてあるので上書きしない。
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    // 横画面では縦が狭いのでスクロール可能にする。
    // viewInsets はソフトキーボード等で隠れる量、SafeArea でノッチ等の余白も避ける。
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final deadPct = (_deadZone * 100).round();
    final extraPx = _extraHit.round();
    final rateHz = _turboRate.round();
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(20, 20, 20, 24 + bottomInset),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.controllerSettings,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),

            // 不感エリア
            Text(l.deadZoneLabel(deadPct)),
            Slider(
              value: _deadZone,
              min: 0.0,
              max: 0.4,
              divisions: 40,
              label: '$deadPct%',
              onChanged: (v) => setState(() => _deadZone = v),
              onChangeEnd: widget.settings.setDeadZoneRatio,
            ),
            Text(
              l.deadZoneHelp,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),

            const SizedBox(height: 16),

            // ボタンヒット拡張
            Text(l.extraHitLabel(extraPx)),
            Slider(
              value: _extraHit,
              min: 0.0,
              max: 40.0,
              divisions: 40,
              label: '+$extraPx px',
              onChanged: (v) => setState(() => _extraHit = v),
              onChangeEnd: widget.settings.setExtraHitRadius,
            ),
            Text(
              l.extraHitHelp,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),

            const SizedBox(height: 16),

            // 連射速度
            Text(l.turboRateLabel(rateHz)),
            Slider(
              value: _turboRate,
              min: 1.0,
              max: 30.0,
              divisions: 29,
              label: '$rateHz Hz',
              onChanged: (v) => setState(() => _turboRate = v),
              onChangeEnd: widget.settings.setTurboRate,
            ),
            Text(
              l.turboRateHelp,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),

            const SizedBox(height: 16),

            // 連射 ON/OFF (per button)
            Text(
              l.turboToggleSection,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in widget.turboCandidates)
                  FilterChip(
                    label: Text(c.label),
                    selected: widget.settings.isTurbo(c.note),
                    onSelected: (v) => widget.settings.setTurbo(c.note, v),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              l.turboToggleHelp,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
