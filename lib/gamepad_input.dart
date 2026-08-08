// ===================================================================================
// 物理ゲームコントローラー入力 (package:gamepads)
//
// gamepads は 0.1.8 に固定している (pubspec 参照)。0.1.9+ は Windows 実装が
// GameInput API になり、gameinput.dll へのロード時リンクが入るため Windows 10 で
// アプリ自体が起動できなくなるリスクがある (加えてビルドに Windows SDK 26100+ が
// 必要)。0.1.8 の GamepadEvent は key がプラットフォーム依存の生文字列なので
// (Android: "KEYCODE_BUTTON_A"/"AXIS_HAT_X"、Windows(winmm): "button-0"/"pov"、
//  iOS: "buttonA"/"dpad - xAxis"、macOS: SF Symbols 名 "a.circle" 等)、
// 本ファイルでプラットフォーム別にデコードして論理コントロール
// (Xbox 標準配置基準) に正規化する。
//
// 各実装の key 仕様の確認元 (pub.dev 解決版のネイティブソース):
//   gamepads_android 0.1.8+2 / gamepads_windows 0.1.4+1 /
//   gamepads_ios 0.1.3+3 / gamepads_darwin 0.1.2+4
//
// 構成:
//   GamepadControl   : 論理コントロール enum
//   GamepadInput     : GamepadEvent ストリーム → (control, pressed) のデコーダ。
//                      アナログスティック/十字キー/POV をヒステリシス付きで
//                      デジタル方向に変換し、複数コントローラーを OR 合成する
//   GamepadNoteBinder: 論理コントロール → note のマッピングと連射 (turbo) 適用。
//                      画面ボタン (_ButtonGroupState) と同じ press/release 挙動
// ===================================================================================

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
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
  l2, // 左トリガー (ZL)
  r2, // 右トリガー (ZR)
  select, // Back / Options
  start, // Start / Menu
}

/// 方向判定に使う軸の種類 (up = +1 / right = +1 に正規化して保持する)。
enum _Axis { dpadX, dpadY, stickX, stickY }

/// 方向判定のソース。十字キーと左スティックは **独立に** ヒステリシス判定して
/// 最後に OR する。両者を合成 (max) してから 1 本のヒステリシスに掛けると、
/// 十字キーを離しても反対ソース (スティック) の残留値が release 閾値を跨いで
/// いる間は方向が押されたままになり、「一瞬だけ入れたのに余計に動く」現象を
/// 起こすため。
enum _DirSource { dpad, stick }

/// GamepadEvent をデコードして論理コントロールの押下変化を通知する。
class GamepadInput {
  GamepadInput({required this.onControl});

  /// 論理コントロールの押下状態が変化したときに呼ばれる。
  final void Function(GamepadControl control, bool pressed) onControl;

  StreamSubscription<GamepadEvent>? _sub;

  // gamepadId ごとの状態。複数コントローラー接続時は最終的に OR 合成する。
  final Map<String, Map<_Axis, double>> _axes = {};
  final Map<String, Set<GamepadControl>> _digitalDirs = {}; // Android の DPAD キー
  // ヒステリシス後の方向。ソース (十字キー / スティック) ごとに独立に持つ。
  final Map<_DirSource, Map<String, Set<GamepadControl>>> _dirState = {
    _DirSource.dpad: {},
    _DirSource.stick: {},
  };
  final Map<String, Set<GamepadControl>> _buttonState = {};

  /// 通知済みの合成押下集合。
  final Set<GamepadControl> _merged = {};

  // アナログ→デジタル変換のヒステリシス閾値。斜め入力 (45° = 0.707) が
  // 両軸とも press になるよう press 閾値は 0.707 未満にする。
  static const double _pressThreshold = 0.55;
  static const double _releaseThreshold = 0.35;

  /// アナログスティックのデッドゾーン。中立でも完全に 0 は返らない
  /// (個体差・経年のオフセット) ため、この範囲は 0 に丸めてから方向判定する。
  /// これを入れないと、わずかなオフセットでも release 閾値 (0.35) を割らずに
  /// 方向が解放されないままになる。斜め入力を潰さないよう press 閾値より
  /// 十分小さく取る。十字キーは元がデジタルなので適用しない。
  static const double _stickDeadzone = 0.2;

  void start() {
    _sub ??= Gamepads.events.listen(_onEvent);
  }

  /// 購読を止め、押下中のコントロールをすべて release 通知する。
  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _axes.clear();
    _digitalDirs.clear();
    for (final perId in _dirState.values) {
      perId.clear();
    }
    _buttonState.clear();
    for (final c in _merged.toList()) {
      _merged.remove(c);
      onControl(c, false);
    }
  }

  void _onEvent(GamepadEvent e) {
    if (Platform.isAndroid) {
      _decodeAndroid(e);
    } else if (Platform.isWindows) {
      _decodeWindows(e);
    } else if (Platform.isIOS || Platform.isMacOS) {
      _decodeDarwin(e);
    } else {
      return;
    }
    _recompute(e.gamepadId);
  }

  // --- プラットフォーム別デコード ------------------------------------------------

  /// Android: key = KeyEvent.keyCodeToString / MotionEvent.axisToString。
  /// AXIS_Y / AXIS_HAT_Y はプラグイン側で反転済み (up = +1)。
  void _decodeAndroid(GamepadEvent e) {
    const buttons = {
      'KEYCODE_BUTTON_A': GamepadControl.south,
      'KEYCODE_BUTTON_B': GamepadControl.east,
      'KEYCODE_BUTTON_X': GamepadControl.west,
      'KEYCODE_BUTTON_Y': GamepadControl.north,
      'KEYCODE_BUTTON_L1': GamepadControl.l1,
      'KEYCODE_BUTTON_R1': GamepadControl.r1,
      'KEYCODE_BUTTON_L2': GamepadControl.l2,
      'KEYCODE_BUTTON_R2': GamepadControl.r2,
      'KEYCODE_BUTTON_SELECT': GamepadControl.select,
      'KEYCODE_BUTTON_START': GamepadControl.start,
    };
    const digitalDirs = {
      'KEYCODE_DPAD_UP': GamepadControl.up,
      'KEYCODE_DPAD_DOWN': GamepadControl.down,
      'KEYCODE_DPAD_LEFT': GamepadControl.left,
      'KEYCODE_DPAD_RIGHT': GamepadControl.right,
    };
    if (e.type == KeyType.button) {
      final btn = buttons[e.key];
      if (btn != null) {
        _setButton(e.gamepadId, btn, e.value > 0.5);
        return;
      }
      final dir = digitalDirs[e.key];
      if (dir != null) {
        final dirs = _digitalDirs.putIfAbsent(e.gamepadId, () => {});
        e.value > 0.5 ? dirs.add(dir) : dirs.remove(dir);
      }
      return;
    }
    switch (e.key) {
      case 'AXIS_X':
        _setAxis(e.gamepadId, _Axis.stickX, e.value);
      case 'AXIS_Y':
        _setAxis(e.gamepadId, _Axis.stickY, e.value); // up = +1 (反転済み)
      case 'AXIS_HAT_X':
        _setAxis(e.gamepadId, _Axis.dpadX, e.value);
      case 'AXIS_HAT_Y':
        _setAxis(e.gamepadId, _Axis.dpadY, e.value); // up = +1 (反転済み)
      // アナログトリガー (0..1)。パッドにより LTRIGGER/RTRIGGER と BRAKE/GAS の
      // どちらで届くかが違うので両方受ける。デジタルボタン扱いに変換する。
      case 'AXIS_LTRIGGER':
      case 'AXIS_BRAKE':
        _setButton(e.gamepadId, GamepadControl.l2, e.value > 0.5);
      case 'AXIS_RTRIGGER':
      case 'AXIS_GAS':
        _setButton(e.gamepadId, GamepadControl.r2, e.value > 0.5);
    }
  }

  /// Windows (winmm): button-N (XInput 系は 0=A,1=B,2=X,3=Y,4=LB,5=RB,6=Back,7=Start)、
  /// スティックは dwXpos/dwYpos (0..65535、y は 0 が上)、十字キーは pov
  /// (方位角の 1/100 度、離すと 65535)。
  void _decodeWindows(GamepadEvent e) {
    const buttons = {
      'button-0': GamepadControl.south,
      'button-1': GamepadControl.east,
      'button-2': GamepadControl.west,
      'button-3': GamepadControl.north,
      'button-4': GamepadControl.l1,
      'button-5': GamepadControl.r1,
      'button-6': GamepadControl.select,
      'button-7': GamepadControl.start,
    };
    if (e.type == KeyType.button) {
      final btn = buttons[e.key];
      if (btn != null) _setButton(e.gamepadId, btn, e.value > 0.5);
      return;
    }
    switch (e.key) {
      case 'dwXpos':
        _setAxis(e.gamepadId, _Axis.stickX, (e.value - 32767.5) / 32767.5);
      case 'dwYpos':
        // winmm は y=0 が上なので符号反転して up = +1 に揃える
        _setAxis(e.gamepadId, _Axis.stickY, (32767.5 - e.value) / 32767.5);
      case 'dwZpos':
        // XInput 系パッドの winmm 互換層はトリガー 2 本を Z 軸 1 本に合成する
        // (中央 = 中立、LT で増加 / RT で減少)。このため L2/R2 の同時押しは
        // 検出できない (winmm の制約)。
        final z = (e.value - 32767.5) / 32767.5;
        _setButton(e.gamepadId, GamepadControl.l2, z > 0.5);
        _setButton(e.gamepadId, GamepadControl.r2, z < -0.5);
      case 'pov':
        if (e.value >= 36000) {
          // released (65535)
          _setAxis(e.gamepadId, _Axis.dpadX, 0);
          _setAxis(e.gamepadId, _Axis.dpadY, 0);
        } else {
          final rad = e.value / 100.0 * math.pi / 180.0; // 0°=上, 90°=右
          _setAxis(e.gamepadId, _Axis.dpadX, math.sin(rad));
          _setAxis(e.gamepadId, _Axis.dpadY, math.cos(rad));
        }
    }
  }

  /// iOS: "buttonA" 等の固有名。macOS: GCController 要素の SF Symbols 名
  /// (menu/options 系のみ 0.1.2+4 から固有名)。
  /// 軸は "dpad - xAxis" / "leftStick - yAxis" (iOS)、
  /// "dpad - xAxis" / "l.joystick - yAxis" 等 (macOS)。yAxis は up = +1。
  void _decodeDarwin(GamepadEvent e) {
    const buttons = {
      // iOS (gamepads_ios) + macOS の固有名
      'buttonA': GamepadControl.south,
      'buttonB': GamepadControl.east,
      'buttonX': GamepadControl.west,
      'buttonY': GamepadControl.north,
      'leftShoulder': GamepadControl.l1,
      'rightShoulder': GamepadControl.r1,
      'leftTrigger': GamepadControl.l2, // iOS (アナログ 0..1)
      'rightTrigger': GamepadControl.r2,
      'buttonOptions': GamepadControl.select,
      'buttonMenu': GamepadControl.start,
      // macOS (gamepads_darwin, SF Symbols 名)
      'a.circle': GamepadControl.south,
      'b.circle': GamepadControl.east,
      'x.circle': GamepadControl.west,
      'y.circle': GamepadControl.north,
      'l1.rectangle.roundedbottom': GamepadControl.l1,
      'r1.rectangle.roundedbottom': GamepadControl.r1,
      'line.horizontal.3.circle': GamepadControl.start,
    };
    final btn = buttons[e.key];
    if (btn != null) {
      _setButton(e.gamepadId, btn, e.value > 0.5);
      return;
    }
    // macOS の SF Symbols 名はコントローラーの刻印に合わせて変わる
    // (Xbox: l1/l2、Switch Pro: l/zl、PS: l1/l2 など)。プレフィックスで拾う。
    final sfBtn = _darwinSfPrefixButton(e.key);
    if (sfBtn != null) {
      _setButton(e.gamepadId, sfBtn, e.value > 0.5);
      return;
    }
    // 軸: key は "<要素名> - xAxis" 形式
    final isX = e.key.endsWith('xAxis');
    final isY = e.key.endsWith('yAxis');
    if (!isX && !isY) return;
    final isDpad = e.key.startsWith('dpad');
    final isLeftStick =
        e.key.startsWith('leftStick') || e.key.startsWith('l.joystick');
    if (isDpad) {
      _setAxis(e.gamepadId, isX ? _Axis.dpadX : _Axis.dpadY, e.value);
    } else if (isLeftStick) {
      _setAxis(e.gamepadId, isX ? _Axis.stickX : _Axis.stickY, e.value);
    }
  }

  /// macOS SF Symbols 名のプレフィックスからバンパー/トリガーを判定する。
  /// 例: "l2.rectangle.roundedtop" (Xbox/PS), "zl.rectangle.roundedtop" (Switch),
  ///     "l.rectangle.roundedbottom" (Switch の L)。
  static GamepadControl? _darwinSfPrefixButton(String key) {
    if (key.startsWith('l2.') || key.startsWith('zl.')) return GamepadControl.l2;
    if (key.startsWith('r2.') || key.startsWith('zr.')) return GamepadControl.r2;
    if (key.startsWith('l.rectangle')) return GamepadControl.l1;
    if (key.startsWith('r.rectangle')) return GamepadControl.r1;
    return null;
  }

  // --- 状態更新と合成 ------------------------------------------------------------

  void _setAxis(String id, _Axis axis, double value) {
    _axes.putIfAbsent(id, () => {})[axis] = value;
  }

  void _setButton(String id, GamepadControl control, bool pressed) {
    final set = _buttonState.putIfAbsent(id, () => {});
    pressed ? set.add(control) : set.remove(control);
  }

  /// [src] 単体での方向の信号強度 (0 以上)。ソースを跨いだ合成はしない
  /// ([_DirSource] のコメント参照)。スティックはデッドゾーンを適用する。
  double _dirSignal(Map<_Axis, double> axes, GamepadControl dir, _DirSource src) {
    final double x, y;
    if (src == _DirSource.dpad) {
      x = axes[_Axis.dpadX] ?? 0;
      y = axes[_Axis.dpadY] ?? 0;
    } else {
      x = _applyDeadzone(axes[_Axis.stickX] ?? 0);
      y = _applyDeadzone(axes[_Axis.stickY] ?? 0);
    }
    switch (dir) {
      case GamepadControl.up:
        return y;
      case GamepadControl.down:
        return -y;
      case GamepadControl.left:
        return -x;
      case GamepadControl.right:
        return x;
      default:
        return 0;
    }
  }

  static double _applyDeadzone(double v) => v.abs() < _stickDeadzone ? 0 : v;

  static const List<GamepadControl> _dirs = [
    GamepadControl.up,
    GamepadControl.down,
    GamepadControl.left,
    GamepadControl.right,
  ];

  void _recompute(String id) {
    final axes = _axes[id] ?? const {};
    final digital = _digitalDirs[id] ?? const {};

    for (final src in _DirSource.values) {
      final dirState = _dirState[src]!.putIfAbsent(id, () => {});
      for (final dir in _dirs) {
        final signal = _dirSignal(axes, dir, src);
        final wasPressed = dirState.contains(dir);
        // ヒステリシス: press は 0.55 超え、release は 0.35 未満で判定。
        // Android のデジタル DPAD キーは無条件で press 扱い (十字キー側のみ)。
        final pressed =
            (src == _DirSource.dpad && digital.contains(dir)) ||
                (wasPressed
                    ? signal > _releaseThreshold
                    : signal > _pressThreshold);
        pressed ? dirState.add(dir) : dirState.remove(dir);
      }
    }

    // 全コントローラー・全ソースの OR 合成 → 変化分を通知
    final next = <GamepadControl>{};
    for (final perId in _dirState.values) {
      for (final s in perId.values) {
        next.addAll(s);
      }
    }
    for (final s in _buttonState.values) {
      next.addAll(s);
    }
    // release を press より先に通知する。1 イベントで方向が反転したとき
    // (例: 十字キー左→右が中立サンプルなしで届く)、press 先行だと
    // NoteOn(右) → NoteOff(左) の順で送信され、受信側で一瞬「左右同時押し」
    // になる。ATARI 出力先が TOWNS パッドの RUN (左右同時) / SELECT (上下同時)
    // と解釈して誤発動するため、必ず反対方向の解放を先に流す。
    for (final c in _merged.difference(next).toList()) {
      _merged.remove(c);
      onControl(c, false);
    }
    for (final c in next.difference(_merged)) {
      _merged.add(c);
      onControl(c, true);
    }
  }
}

/// 論理コントロール → note のマッピングと連射 (turbo) を適用して
/// MidiService.joystickPress/Release を駆動する。
///
/// - 方向キーと Start/Back (RUN/SELECT 等) は [mapping] の固定割り当て
/// - ボタン類 ([assignable]) は [JoystickSettings.padAssign] の割り当てに従う。
///   連射フラグも割り当て側 (物理ボタン単位) に付く。複数の物理ボタンが同じ
///   note を指せるため、note の press/release は参照カウントで多重化する
/// - turbo の press/release トグル周期は画面ボタンと同じ turboRate を使う
class GamepadNoteBinder {
  GamepadNoteBinder({
    required this.midi,
    required this.settings,
    required this.mapping,
    this.pressedNotes,
    this.pressedControls,
    this.noteGate,
  }) {
    _lastTurboRate = settings.turboRate;
    settings.addListener(_onSettingsChanged);
    _input = GamepadInput(onControl: _onControl);
    _input.start();
  }

  final MidiService midi;
  final JoystickSettings settings;

  /// 固定マッピング (方向キー + Start/Back)。[assignable] のコントロールは
  /// このマップではなく settings.padAssign を参照する。
  final Map<GamepadControl, int> mapping;

  /// パッド起因で論理押下中の note 集合を UI へ通知する (画面ボタンの発光連動用)。
  /// null なら通知しない。
  final ValueNotifier<Set<int>>? pressedNotes;

  /// 物理コントロールの生の押下状態を UI へ通知する (割り当て設定画面の
  /// 行ハイライト用)。割り当ての有無に関わらず全コントロールが流れる。
  final ValueNotifier<Set<GamepadControl>>? pressedControls;

  /// note の押下を許可するかの動的ゲート (null なら全許可)。
  /// 設定トグル (例: TOWNS パッド機能) で一部 note を無効化するのに使う。
  /// press のみゲートし release は素通しにすることで、押下中にゲートが
  /// 閉じても note が押しっぱなしで残らないようにしている。
  final bool Function(int note)? noteGate;

  /// 割り当て変更可能な物理コントロール (JoystickSettings.assignableControls と同順)。
  static const List<GamepadControl> assignable = [
    GamepadControl.south,
    GamepadControl.east,
    GamepadControl.west,
    GamepadControl.north,
    GamepadControl.l1,
    GamepadControl.r1,
    GamepadControl.l2,
    GamepadControl.r2,
  ];

  late final GamepadInput _input;

  /// 押下中コントロール → そのコントロールが発行した note。
  /// 押下中に割り当てを変更しても、離すまでは押下時の note を使う。
  final Map<GamepadControl, int> _heldNotes = {};

  /// note ごとの press 参照カウント。0→1 で NoteOn、1→0 で NoteOff を送る。
  final Map<int, int> _noteRefs = {};

  /// turbo 中のコントロールの物理位相 (true = press 中)。
  final Map<GamepadControl, bool> _turboPhase = {};

  /// 生の押下状態 (pressedControls 通知用)。
  final Set<GamepadControl> _rawPressed = {};

  Timer? _turboTimer;
  late double _lastTurboRate;

  bool _disposed = false;

  int? _noteFor(GamepadControl control) {
    if (assignable.contains(control)) {
      return settings.padAssign(control.name).note;
    }
    return mapping[control];
  }

  bool _turboFor(GamepadControl control) =>
      assignable.contains(control) && settings.padAssign(control.name).turbo;

  void _refPress(int note) {
    final refs = (_noteRefs[note] ?? 0) + 1;
    _noteRefs[note] = refs;
    if (refs == 1) midi.joystickPress(note);
  }

  void _refRelease(int note) {
    final refs = (_noteRefs[note] ?? 0) - 1;
    if (refs <= 0) {
      _noteRefs.remove(note);
      midi.joystickRelease(note);
    } else {
      _noteRefs[note] = refs;
    }
  }

  void _onControl(GamepadControl control, bool pressed) {
    // 生の押下状態は割り当ての有無に関わらず通知する (設定画面のハイライト用)
    pressed ? _rawPressed.add(control) : _rawPressed.remove(control);
    pressedControls?.value = Set.unmodifiable(_rawPressed);

    if (pressed) {
      if (_heldNotes.containsKey(control)) return;
      final note = _noteFor(control);
      if (note == null) return;
      if (noteGate != null && !noteGate!(note)) return;
      _heldNotes[control] = note;
      if (_turboFor(control)) _turboPhase[control] = true;
      _refPress(note);
    } else {
      final note = _heldNotes.remove(control);
      if (note == null) return;
      final phase = _turboPhase.remove(control);
      // turbo の OFF 位相で止まっていた場合は既に release 済み
      if (phase == null || phase) _refRelease(note);
    }
    pressedNotes?.value = Set.unmodifiable(_heldNotes.values.toSet());
    _ensureTurboTimer();
  }

  void _ensureTurboTimer() {
    final hasActiveTurbo = _turboPhase.isNotEmpty;
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
    for (final control in _turboPhase.keys.toList()) {
      final note = _heldNotes[control];
      if (note == null) continue;
      final nowPressed = !_turboPhase[control]!;
      _turboPhase[control] = nowPressed;
      nowPressed ? _refPress(note) : _refRelease(note);
    }
  }

  /// 設定変更 (割り当ての連射フラグ / レート) へ押下中のコントロールを追従させる。
  void _onSettingsChanged() {
    for (final control in _heldNotes.keys.toList()) {
      final wantTurbo = _turboFor(control);
      final isTurbo = _turboPhase.containsKey(control);
      if (wantTurbo && !isTurbo) {
        // 押しっぱなし (press 中) から turbo サイクルへ
        _turboPhase[control] = true;
      } else if (!wantTurbo && isTurbo) {
        // turbo → 通常: OFF 位相で止まっていたら押し直す
        final phase = _turboPhase.remove(control)!;
        if (!phase) _refPress(_heldNotes[control]!);
      }
    }

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

// ---------------------------------------------------------------------------
// 固定マッピング定義 (ジョイスティック画面のモードと共有)
// ---------------------------------------------------------------------------

/// ATARI 互換モード: 十字キー/左スティック → 方向、下ボタン → A、右ボタン → B。
/// Start/Back は TOWNS パッドの RUN/SELECT (設定の「TOWNSパッド機能」が ON のとき
/// のみ有効 — noteGate 参照)。
const Map<GamepadControl, int> atariGamepadMapping = {
  GamepadControl.up: MidiService.noteUp,
  GamepadControl.down: MidiService.noteDown,
  GamepadControl.left: MidiService.noteLeft,
  GamepadControl.right: MidiService.noteRight,
  GamepadControl.south: MidiService.noteA,
  GamepadControl.east: MidiService.noteB,
  GamepadControl.start: MidiService.noteRun,
  GamepadControl.select: MidiService.noteSelect,
};

/// モードの固定マッピングから JoystickSettings 用の既定パッド割り当て
/// (コントロール名 → note) を作る。割り当て変更可能なボタンだけを抜き出す
/// (方向キーと Start/Back は含まれない)。
Map<String, int> defaultPadAssignOf(Map<GamepadControl, int> mapping) => {
      for (final c in GamepadNoteBinder.assignable)
        if (mapping.containsKey(c)) c.name: mapping[c]!,
    };

/// TOWNS パッド機能のトグルに応じて RUN/SELECT ノートをゲートする述語を作る。
/// ATARI モードの GamepadNoteBinder に渡す。
bool Function(int note) townsPadNoteGate(JoystickSettings settings) =>
    (note) =>
        (note != MidiService.noteRun && note != MidiService.noteSelect) ||
        settings.townsPad;

/// MD 6B モード: 下段 (X/A/B) → A/B/C、上段 (LB/Y/RB) → X/Y/Z、
/// Start → START、Back → MODE。
const Map<GamepadControl, int> md6GamepadMapping = {
  GamepadControl.up: MidiService.noteUp,
  GamepadControl.down: MidiService.noteDown,
  GamepadControl.left: MidiService.noteLeft,
  GamepadControl.right: MidiService.noteRight,
  GamepadControl.west: MidiService.noteA,
  GamepadControl.south: MidiService.noteB,
  GamepadControl.east: MidiService.noteC,
  GamepadControl.l1: MidiService.noteX,
  GamepadControl.north: MidiService.noteY,
  GamepadControl.r1: MidiService.noteZ,
  GamepadControl.start: MidiService.noteStart,
  GamepadControl.select: MidiService.noteMode,
};
