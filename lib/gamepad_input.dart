// ===================================================================================
// 物理ゲームコントローラー入力 (package:gamepads)
//
// gamepads 0.1.10 の正規化イベント (Gamepads.normalizedEvents) を使う。
// プラットフォーム依存の生 key はパッケージ側で Xbox 標準配置の
// GamepadButton / GamepadAxis に正規化される (十字キーは POV/HAT 軸であっても
// dpadUp/Down/Left/Right のボタンイベントに変換される)。
//
// 本ファイルの責務:
//   GamepadControl   : アプリ内の論理コントロール enum
//   GamepadInput     : 正規化イベント → (control, pressed) への変換。
//                      左スティックはヒステリシス付きでデジタル方向化し、
//                      十字キーと OR 合成。複数コントローラーも OR 合成する
//   GamepadNoteBinder: 論理コントロール → note のマッピングと連射 (turbo) 適用。
//                      画面ボタン (_ButtonGroupState) と同じ press/release 挙動
// ===================================================================================

import 'dart:async';
import 'dart:math' as math;

import 'package:gamepads/gamepads.dart';

import 'joystick_settings.dart';
import 'midi_service.dart';

/// 論理コントロール。ボタン名は Xbox 標準配置の物理位置 (south = 下ボタン = A)。
/// Nintendo 系コントローラーでは刻印と位置が入れ替わるが、位置基準で統一する。
enum GamepadControl {
  up,
  down,
  left,
  right,
  south, // Xbox A (下)
  east, // Xbox B (右)
  west, // Xbox X (左)
  north, // Xbox Y (上)
  l1, // 左バンパー
  r1, // 右バンパー
  select, // Back / Options
  start, // Start / Menu
}

/// 正規化イベントをデコードして論理コントロールの押下変化を通知する。
class GamepadInput {
  GamepadInput({required this.onControl});

  /// 論理コントロールの押下状態が変化したときに呼ばれる。
  final void Function(GamepadControl control, bool pressed) onControl;

  StreamSubscription<NormalizedGamepadEvent>? _sub;

  // gamepadId ごとの状態。複数コントローラー接続時は最終的に OR 合成する。
  final Map<String, Set<GamepadControl>> _buttonState = {}; // dpad 含む
  final Map<String, double> _stickX = {};
  final Map<String, double> _stickY = {};
  final Map<String, Set<GamepadControl>> _stickDirState = {}; // ヒステリシス後

  /// 通知済みの合成押下集合。
  final Set<GamepadControl> _merged = {};

  // スティックのアナログ→デジタル変換のヒステリシス閾値。
  // 斜め入力 (45° = 0.707) が両軸とも press になるよう press 閾値は 0.707 未満。
  static const double _pressThreshold = 0.55;
  static const double _releaseThreshold = 0.35;

  static const Map<GamepadButton, GamepadControl> _buttonMap = {
    GamepadButton.dpadUp: GamepadControl.up,
    GamepadButton.dpadDown: GamepadControl.down,
    GamepadButton.dpadLeft: GamepadControl.left,
    GamepadButton.dpadRight: GamepadControl.right,
    GamepadButton.a: GamepadControl.south,
    GamepadButton.b: GamepadControl.east,
    GamepadButton.x: GamepadControl.west,
    GamepadButton.y: GamepadControl.north,
    GamepadButton.leftBumper: GamepadControl.l1,
    GamepadButton.rightBumper: GamepadControl.r1,
    GamepadButton.back: GamepadControl.select,
    GamepadButton.start: GamepadControl.start,
  };

  void start() {
    _sub ??= Gamepads.normalizedEvents.listen(_onEvent);
  }

  /// 購読を止め、押下中のコントロールをすべて release 通知する。
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _buttonState.clear();
    _stickX.clear();
    _stickY.clear();
    _stickDirState.clear();
    for (final c in _merged.toList()) {
      _merged.remove(c);
      onControl(c, false);
    }
  }

  void _onEvent(NormalizedGamepadEvent e) {
    final button = e.button;
    if (button != null) {
      final control = _buttonMap[button];
      if (control == null) return;
      final set = _buttonState.putIfAbsent(e.gamepadId, () => {});
      e.value > 0.5 ? set.add(control) : set.remove(control);
    } else {
      switch (e.axis) {
        case GamepadAxis.leftStickX:
          _stickX[e.gamepadId] = e.value; // right = +1
        case GamepadAxis.leftStickY:
          _stickY[e.gamepadId] = e.value; // up = +1
        default:
          return;
      }
      _recomputeStick(e.gamepadId);
    }
    _notifyMerged();
  }

  /// 左スティックをヒステリシス付きでデジタル方向化する。
  void _recomputeStick(String id) {
    final x = _stickX[id] ?? 0;
    final y = _stickY[id] ?? 0;
    final state = _stickDirState.putIfAbsent(id, () => {});

    void update(GamepadControl dir, double signal) {
      final wasPressed = state.contains(dir);
      final pressed =
          wasPressed ? signal > _releaseThreshold : signal > _pressThreshold;
      pressed ? state.add(dir) : state.remove(dir);
    }

    update(GamepadControl.up, y);
    update(GamepadControl.down, -y);
    update(GamepadControl.left, -x);
    update(GamepadControl.right, x);
  }

  /// 全コントローラー + 全入力源を OR 合成し、変化分だけ通知する。
  void _notifyMerged() {
    final next = <GamepadControl>{};
    for (final s in _buttonState.values) {
      next.addAll(s);
    }
    for (final s in _stickDirState.values) {
      next.addAll(s);
    }
    for (final c in next.difference(_merged)) {
      _merged.add(c);
      onControl(c, true);
    }
    for (final c in _merged.difference(next).toList()) {
      _merged.remove(c);
      onControl(c, false);
    }
  }
}

/// 論理コントロール → note のマッピングと連射 (turbo) を適用して
/// MidiService.joystickPress/Release を駆動する。
///
/// turbo の挙動は画面ボタン (_ButtonGroupState) と同一:
///   - 押下: 即時 press、turbo 対象ならタイマーで press/release をトグル
///   - 離し: turbo 対象は「物理 press 中なら release」、通常は即 release
class GamepadNoteBinder {
  GamepadNoteBinder({
    required this.midi,
    required this.settings,
    required this.mapping,
  }) {
    _lastTurboNotes = settings.turboNotes;
    _lastTurboRate = settings.turboRate;
    settings.addListener(_onSettingsChanged);
    _input = GamepadInput(onControl: _onControl);
    _input.start();
  }

  final MidiService midi;
  final JoystickSettings settings;
  final Map<GamepadControl, int> mapping;

  late final GamepadInput _input;

  /// 論理的に押下中の note (turbo の物理トグルとは独立)。
  final Set<int> _activeNotes = {};

  /// turbo 対象 note の物理状態 (true = press 中)。
  final Map<int, bool> _turboPressed = {};

  Timer? _turboTimer;
  late Set<int> _lastTurboNotes;
  late double _lastTurboRate;

  bool _disposed = false;

  void _onControl(GamepadControl control, bool pressed) {
    final note = mapping[control];
    if (note == null) return;
    if (pressed) {
      if (!_activeNotes.add(note)) return;
      midi.joystickPress(note);
      if (settings.isTurbo(note)) _turboPressed[note] = true;
    } else {
      if (!_activeNotes.remove(note)) return;
      if (settings.isTurbo(note)) {
        if (_turboPressed[note] == true) midi.joystickRelease(note);
        _turboPressed.remove(note);
      } else {
        midi.joystickRelease(note);
      }
    }
    _ensureTurboTimer();
  }

  void _ensureTurboTimer() {
    final hasActiveTurbo = _activeNotes.any(settings.isTurbo);
    if (hasActiveTurbo && _turboTimer == null) {
      _startTurboTimer();
    } else if (!hasActiveTurbo && _turboTimer != null) {
      _stopTurboTimer();
    }
  }

  void _startTurboTimer() {
    final periodMs = math.max(16, (1000 / (2 * settings.turboRate)).round());
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
      if (!settings.isTurbo(note)) continue;
      final nowPressed = !(_turboPressed[note] ?? false);
      _turboPressed[note] = nowPressed;
      nowPressed ? midi.joystickPress(note) : midi.joystickRelease(note);
    }
  }

  /// turbo 設定 (対象 note / レート) の変更へ追従する
  /// (_ButtonGroupState.didUpdateWidget と同じ調整)。
  void _onSettingsChanged() {
    final turboNotes = settings.turboNotes;
    // turbo → 非 turbo: release 半サイクルで止まっていたら押し直す
    for (final note in _lastTurboNotes.difference(turboNotes)) {
      if (_activeNotes.contains(note) && _turboPressed[note] != true) {
        midi.joystickPress(note);
      }
      _turboPressed.remove(note);
    }
    // 非 turbo → turbo: press 状態から turbo サイクルへ
    for (final note in turboNotes.difference(_lastTurboNotes)) {
      if (_activeNotes.contains(note)) _turboPressed[note] = true;
    }
    _lastTurboNotes = turboNotes;

    if (_lastTurboRate != settings.turboRate) {
      _lastTurboRate = settings.turboRate;
      if (_turboTimer != null) {
        _stopTurboTimer();
        _startTurboTimer();
      }
    }
    _ensureTurboTimer();
  }

  /// 押下中の note をすべて解放して停止する。複数回呼んでも安全。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    settings.removeListener(_onSettingsChanged);
    _stopTurboTimer();
    // stop() が押下中コントロールの release を onControl 経由で通知するので、
    // ここで note の解放も完了する。
    await _input.stop();
  }
}
