// ===================================================================================
// X68000 仮想キーボード画面
// ===================================================================================
// レイアウトは X68000 実機キーボードを参考にした JIS 配列。
// スキャンコードはプロトコル仕様 Appendix A 参照。
// ===================================================================================

import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'channel_mode.dart';
import 'l10n/app_localizations.dart';
import 'midi_service.dart';
import 'mode_scaffold.dart';
import 'protocol.dart';
import 'orientation_helper.dart';
import 'sjis_encoder.dart';
import 'windows_ime.dart';
import 'x68k_shared_state.dart';
import 'x68k_target_rx_log_page.dart';

// ===========================================================================
// X68kKeyboardPage 本体
// 当面はモードが 1 つ (StandardX68kMode) だけだが、将来フリック入力モード等を
// 増やす想定で ModeScaffold に乗せている。1 モードならドロップダウンは非表示。
// ===========================================================================

class X68kKeyboardPage extends StatefulWidget {
  final MidiService midi;
  final int channel;

  /// 同一デバイスがマウス機能も持つときの MIDI チャンネル。null ならトラックパッド非表示。
  final int? mouseChannel;

  /// AppBar title 下に表示するアダプタ名 (ニックネームまたは USB iProduct)。
  /// null/空ならサブタイトル非表示。
  final String? deviceName;

  /// アダプタ個体のシリアル (Chip UID 由来 16 桁 hex)。
  /// テンキー / トラックパッドの表示トグルをこの serial をキーに永続化する。
  /// null/空なら永続化なし (in-memory only)。
  final String? serial;

  /// Combined デバイスの同時セッションでジョイスティック画面へ切り替えるボタンを
  /// 表示する。null なら非表示 (従来どおり単機能ページ)。
  final VoidCallback? onSwitchToJoystick;

  /// この画面が前面 (アクティブ) か。Combined セッションで IndexedStack に同時
  /// 生存させる際、前面のときだけ画面の向き・IME・物理キーボード送信を有効にする。
  /// 単機能ページでは常に true。
  final bool active;

  /// ハートビートをこのページ自身で管理するか。Combined セッションでは
  /// ホスト (CombinedSessionPage) が 1 本所有するので false を渡す。
  final bool manageHeartBeat;

  const X68kKeyboardPage({
    super.key,
    required this.midi,
    this.channel = MidiService.chKeyboardDefault,
    this.mouseChannel,
    this.deviceName,
    this.serial,
    this.onSwitchToJoystick,
    this.active = true,
    this.manageHeartBeat = true,
  });

  @override
  State<X68kKeyboardPage> createState() => _X68kKeyboardPageState();
}

class _X68kKeyboardPageState extends State<X68kKeyboardPage> {
  /// Standard / LineInput 共通の状態 (LED 点灯、輝度、キーリピート設定)。
  /// onTargetRx ハンドラは page 自身が握って shared に流す。
  late final X68kKeyboardSharedState _shared;
  late final List<ChannelMode> _modes;

  @override
  void initState() {
    super.initState();
    // 向きと IME は各モードの onActiveChanged で「前面のときだけ」制御する
    // (Standard は landscape、LineInput は unlock + IME)。Combined で背面の
    // ときは相手画面が制御するので何もしない。
    _shared = X68kKeyboardSharedState(serial: widget.serial);
    // TARGET_RX を page で受けて shared に転送する。冪等パターン (既に同じ
    // closure なら触らない / dispose 時は自分がまだ active な時のみクリア)。
    widget.midi.onTargetRx = _onTargetRx;
    _modes = [
      StandardX68kMode(
        channel: widget.channel,
        mouseChannel: widget.mouseChannel,
        shared: _shared,
        serial: widget.serial,
      ),
      LineInputMode(channel: widget.channel, shared: _shared),
      TvRemoteMode(),
    ];
    // 起動直後に LED 状態を本体と同期する。X68000 からは "現在の LED 状態を
    // 問い合わせる" 直接的な手段が無いので、何か LED トグルキーを押して
    // X68000 が返す LED 制御コマンド (= 全 7 ビットの現状を含むメッセージ)
    // で状態を学習する。
    //
    // 全 7 キーを次々に押すと、排他関係のあるキー (かな↔ローマ字 / ひらがな等)
    // で状態遷移がズレる恐れがあるため、INS (他と排他関係を持たない) を
    // 2 回押して 1 回目で全 LED 状態を読み取り、2 回目で INS を元に戻す。
    Future.delayed(const Duration(milliseconds: 500), _syncLedState);
    // 操作画面に入っている間は HB を送り続ける。3 秒応答が無ければ "CONN_LOST"
    // を結果にして自動 pop。HomePage 側で再 scan される。
    // Combined セッションではホストが HB を所有するのでページ側では管理しない。
    if (widget.manageHeartBeat) {
      widget.midi.startHeartBeat(onFailure: _onHeartBeatFailure);
    }
  }

  void _onHeartBeatFailure() {
    if (!mounted) return;
    Navigator.of(context).pop('CONN_LOST');
  }

  void _onTargetRx(int midiChannel, int byte) {
    if (midiChannel != widget.channel) return;
    _shared.handleTargetRxByte(byte);
  }

  Future<void> _syncLedState() async {
    const insScancode = 0x5E;
    for (int i = 0; i < 2; i++) {
      if (!mounted) return;
      widget.midi.sendNoteOn(widget.channel, insScancode, 127);
      await Future.delayed(const Duration(milliseconds: 30));
      widget.midi.sendNoteOff(widget.channel, insScancode);
      // X68000 側で LED 状態を更新 → LED 制御コマンドを返す処理に十分余裕を持たせる
      await Future.delayed(const Duration(milliseconds: 200));
    }
  }

  @override
  void dispose() {
    // HB だけ早めに止めておく (joystick_page と同じ理由)。DISCONNECT 送信 +
    // USB close は親 (main.dart) が Navigator.push の await 後にまとめて行う。
    // Combined セッションではホストが HB を所有するのでページ側では止めない。
    if (widget.manageHeartBeat) widget.midi.stopHeartBeat();
    if (widget.midi.onTargetRx == _onTargetRx) {
      widget.midi.onTargetRx = null;
    }
    for (final m in _modes) {
      m.dispose();
    }
    _shared.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ModeScaffold(
      title: AppLocalizations.of(context)!.x68kKeyboardTitle,
      subtitle: widget.deviceName,
      midi: widget.midi,
      modes: _modes,
      active: widget.active,
      persistenceKey: 'x68k_keyboard.selectedMode',
      extraActions: [
        if (widget.onSwitchToJoystick != null)
          IconButton(
            icon: const Icon(Icons.sports_esports),
            tooltip: AppLocalizations.of(context)!.switchToJoystick,
            onPressed: widget.onSwitchToJoystick,
          ),
      ],
    );
  }
}

// ===========================================================================
// X68000 標準キーボードモード
// テンキー / トラックパッドの表示トグルはこのモードの状態として保持し、
// AppBar アクションとして提供する。
// ===========================================================================

class StandardX68kMode extends ChannelMode {
  final int channel;
  final int? mouseChannel;
  final X68kKeyboardSharedState shared;

  /// テンキー / トラックパッド表示の永続化キー prefix にするアダプタ個体の serial。
  /// null/空なら永続化しない (in-memory のみ)。
  final String? serial;

  bool _numpadVisible = true;
  bool _trackpadVisible = true;

  /// 物理キーボード入力モード。
  ///   false (デフォルト): X68k 配列モード — PhysicalKeyboardKey ベースで JIS
  ///                       物理位置をそのまま X68k スキャンコードに対応付ける。
  ///                       JIS 物理キーボードなら刻印通りに打てる。
  ///   true:              PC キーボードモード — 記号系のキーは KeyEvent.character
  ///                       を見て X68k 上の対応キー (+ 必要なら SHIFT 補正) に
  ///                       マッピングする。US 物理キーボードでも「Shift+2 で @」の
  ///                       感覚で打てる。
  /// 個別アダプタの設定ではなくホスト側 (= ユーザ環境) の設定なので、シリアル
  /// 接頭辞なしで永続化する。
  bool _pcKeyboardMode = false;
  bool get pcKeyboardMode => _pcKeyboardMode;

  /// デスクトップ環境で複数キー同時押し相当を実現するための sticky 状態。
  /// 本体 (_X68kKeyboardBody) が読み書きし、AppBar の "全解除" ボタンも
  /// このコントローラを購読することで表示可否を切り替える。
  final StickyKeyController stickyController = StickyKeyController();

  StandardX68kMode({
    required this.channel,
    this.mouseChannel,
    required this.shared,
    this.serial,
  }) {
    // serial が分かれば、保存済みの表示設定を非同期で読み込む。
    // 読み込み完了後に notifyListeners() で本体を再描画させる。
    _loadVisibility();
    _loadPcKeyboardMode();
  }

  // ---------------------------------------------------------------------------
  // テンキー / トラックパッド表示状態のシリアル別永続化
  // ---------------------------------------------------------------------------
  String get _kNumpadVisible => 'x68k_keyboard.$serial.numpadVisible';
  String get _kTrackpadVisible => 'x68k_keyboard.$serial.trackpadVisible';
  // PC キーボードモードはホスト環境の設定なので serial で切らない。
  static const String _kPcKeyboardMode = 'x68k_keyboard.pcKeyboardMode';

  Future<void> _loadVisibility() async {
    final s = serial;
    if (s == null || s.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final n = prefs.getBool(_kNumpadVisible);
      final t = prefs.getBool(_kTrackpadVisible);
      if (n != null) _numpadVisible = n;
      if (t != null) _trackpadVisible = t;
      if (n != null || t != null) notifyListeners();
    } catch (_) {
      // 読み込み失敗は初期値のままで続行
    }
  }

  Future<void> _persistVisibility() async {
    final s = serial;
    if (s == null || s.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kNumpadVisible, _numpadVisible);
      await prefs.setBool(_kTrackpadVisible, _trackpadVisible);
    } catch (_) {
      // 保存失敗は無視 (致命的ではない)
    }
  }

  Future<void> _loadPcKeyboardMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final v = prefs.getBool(_kPcKeyboardMode);
      if (v != null && v != _pcKeyboardMode) {
        _pcKeyboardMode = v;
        notifyListeners();
      }
    } catch (_) {
      // 読み込み失敗は初期値 (X68k 配列モード) のまま
    }
  }

  Future<void> _persistPcKeyboardMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPcKeyboardMode, _pcKeyboardMode);
    } catch (_) {
      // 保存失敗は無視
    }
  }

  @override
  String get id => 'x68k_keyboard.standard';

  @override
  String label(BuildContext context) => '標準';

  @override
  @override
  void onActiveChanged(bool active, MidiService midi) {
    // キーボードレイアウトは横向き専用。前面のときだけ向きを固定する
    // (Combined で背面のときは相手画面の向きを尊重)。
    if (active) OrientationHelper.landscape();
  }

  void _toggleNumpad() {
    _numpadVisible = !_numpadVisible;
    notifyListeners();
    _persistVisibility();
  }

  void _toggleTrackpad() {
    _trackpadVisible = !_trackpadVisible;
    notifyListeners();
    _persistVisibility();
  }

  void _togglePcKeyboardMode() {
    _pcKeyboardMode = !_pcKeyboardMode;
    notifyListeners();
    _persistPcKeyboardMode();
  }

  @override
  Widget buildBody(BuildContext context, MidiService midi) {
    // body の subtree 内では Flutter のフォーカス系キー処理を完全に遮断する。
    // 物理キー入力は body 内 (_X68kKeyboardBody) が HardwareKeyboard.addHandler
    // 経由で MIDI に転送するため、widget tree のキー処理は不要。
    //   - autofocus: true            → mount 時に focus を取り、body 内の
    //                                  Focusable widget に focus が落ちないように
    //   - descendantsAreFocusable: false → 配下を一切 focus 不可
    //   - onKeyEvent: handled       → 来たキーイベントを全消費
    // AppBar 側の戻るボタンは ModeScaffold 側で ExcludeFocus 済み。
    return Focus(
      autofocus: true,
      descendantsAreFocusable: false,
      onKeyEvent: (node, event) => KeyEventResult.handled,
      child: _X68kKeyboardBody(
        midi: midi,
        channel: channel,
        mouseChannel: mouseChannel,
        numpadVisible: _numpadVisible,
        trackpadVisible: _trackpadVisible,
        pcKeyboardMode: _pcKeyboardMode,
        stickyController: stickyController,
        shared: shared,
      ),
    );
  }

  @override
  List<Widget> buildActions(BuildContext context) {
    return [
      // Sticky 全解除: stuck キーが 1 つ以上あるときだけ表示。
      ListenableBuilder(
        listenable: stickyController,
        builder: (_, __) {
          if (!stickyController.hasStuck) return const SizedBox.shrink();
          return IconButton(
            tooltip: 'Sticky を全て解除',
            icon: const Icon(Icons.lock_open),
            onPressed: stickyController.onReleaseAllRequested,
          );
        },
      ),
      IconButton(
        tooltip: _pcKeyboardMode
            ? '物理キーボード: PC 配列モード (Shift+2 で @ 等)'
            : '物理キーボード: X68k 配列モード (JIS 物理位置基準)',
        icon: Icon(_pcKeyboardMode ? Icons.keyboard_alt : Icons.keyboard),
        onPressed: _togglePcKeyboardMode,
      ),
      if (mouseChannel != null)
        IconButton(
          tooltip: _trackpadVisible ? 'トラックパッドを非表示' : 'トラックパッドを表示',
          icon: Icon(
              _trackpadVisible ? Icons.touch_app : Icons.touch_app_outlined),
          onPressed: _toggleTrackpad,
        ),
      IconButton(
        tooltip: _numpadVisible ? 'テンキーを非表示' : 'テンキーを表示',
        icon: Icon(_numpadVisible ? Icons.dialpad : Icons.dialpad_outlined),
        onPressed: _toggleNumpad,
      ),
      IconButton(
        tooltip: '受信ログ',
        icon: const Icon(Icons.history),
        onPressed: () {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => X68kTargetRxLogPage(shared: shared),
          ));
        },
      ),
    ];
  }

  @override
  void dispose() {
    stickyController.dispose();
    super.dispose();
  }
}

// ===========================================================================
// 複数キー同時押し用 sticky 状態の共有コントローラ
//
// マウスクリック (= デスクトップ) では指 1 本ぶんしか押せないため、
//   - 左クリック (左タップ): Modifier キー (SHIFT/CTRL/OPT/XF) は自動 sticky、
//                          すでに stuck のキーは 1 クリックで解除
//   - 右クリック        : 任意キーの sticky を toggle
// という UX を提供する。タッチ入力 (kind != mouse) では従来通り押下中だけ
// 反応する。AppBar の "全解除" ボタンと本体側で状態を共有するためにこの
// ChangeNotifier 経由でやり取りする。
// ===========================================================================

class StickyKeyController extends ChangeNotifier {
  final Set<int> _stuck = {};

  Set<int> get stuck => Set.unmodifiable(_stuck);
  bool get hasStuck => _stuck.isNotEmpty;
  bool isStuck(int code) => _stuck.contains(code);

  bool add(int code) {
    final added = _stuck.add(code);
    if (added) notifyListeners();
    return added;
  }

  bool remove(int code) {
    final removed = _stuck.remove(code);
    if (removed) notifyListeners();
    return removed;
  }

  void clear() {
    if (_stuck.isEmpty) return;
    _stuck.clear();
    notifyListeners();
  }

  /// body 側が initState で登録する「全 stuck 解除」コールバック。
  /// AppBar の解除ボタンはこの参照を経由して body の処理を呼ぶ。
  VoidCallback? onReleaseAllRequested;
}

/// 左クリック (kind == mouse) で自動 sticky する Modifier 系スキャンコード。
/// LED 系 (かな/CAPS/INS 等) は X68k 側で push 1 回でトグルする仕様なので、
/// sticky 化しなくてもデスクトップから操作可能。
const Set<int> _stickyModifierScancodes = {
  0x55, // XF1
  0x56, // XF2
  0x57, // XF3
  0x58, // XF4
  0x59, // XF5
  0x70, // SHIFT
  0x71, // CTRL
  0x72, // OPT.1
  0x73, // OPT.2
};

// ===========================================================================
// キーボード本体 Widget。AppBar 以外のすべての本体ロジック
// (キー押下/リリース、リピート、ポップアップ、LED 状態、レイアウト等) を担う。
// ===========================================================================

class _X68kKeyboardBody extends StatefulWidget {
  final MidiService midi;
  final int channel;
  final int? mouseChannel;
  final bool numpadVisible;
  final bool trackpadVisible;
  final bool pcKeyboardMode;
  final StickyKeyController stickyController;
  final X68kKeyboardSharedState shared;

  const _X68kKeyboardBody({
    required this.midi,
    required this.channel,
    required this.mouseChannel,
    required this.numpadVisible,
    required this.trackpadVisible,
    required this.pcKeyboardMode,
    required this.stickyController,
    required this.shared,
  });

  @override
  State<_X68kKeyboardBody> createState() => _X68kKeyboardBodyState();
}

class _X68kKeyboardBodyState extends State<_X68kKeyboardBody> {
  // 押下中のキー (重複送信防止用)
  final Set<int> _pressed = {};

  // ひらがな・全角は緑、それ以外 (かな/ローマ字/コード入力/CAPS/INS) は赤
  static const Set<int> _greenLedScancodes = {0x5F, 0x60};

  // X68000 JIS かな配列: かな ON + ひらがな ON のとき表示
  static const Map<int, String> _hiraganaLabels = {
    0x02: 'ぬ', 0x03: 'ふ', 0x04: 'あ', 0x05: 'う', 0x06: 'え',
    0x07: 'お', 0x08: 'や', 0x09: 'ゆ', 0x0A: 'よ', 0x0B: 'わ',
    0x0C: 'ほ', 0x0D: 'へ', 0x0E: 'ー',
    0x11: 'た', 0x12: 'て', 0x13: 'い', 0x14: 'す', 0x15: 'か',
    0x16: 'ん', 0x17: 'な', 0x18: 'に', 0x19: 'ら', 0x1A: 'せ',
    0x1B: '゛', 0x1C: '゜',
    0x1E: 'ち', 0x1F: 'と', 0x20: 'し', 0x21: 'は', 0x22: 'き',
    0x23: 'く', 0x24: 'ま', 0x25: 'の', 0x26: 'り', 0x27: 'れ',
    0x28: 'け', 0x29: 'む',
    0x2A: 'つ', 0x2B: 'さ', 0x2C: 'そ', 0x2D: 'ひ', 0x2E: 'こ',
    0x2F: 'み', 0x30: 'も', 0x31: 'ね', 0x32: 'る', 0x33: 'め',
    0x34: 'ろ',
  };

  // かな ON + ひらがな OFF のとき表示するカタカナラベル
  static const Map<int, String> _katakanaLabels = {
    0x02: 'ヌ', 0x03: 'フ', 0x04: 'ア', 0x05: 'ウ', 0x06: 'エ',
    0x07: 'オ', 0x08: 'ヤ', 0x09: 'ユ', 0x0A: 'ヨ', 0x0B: 'ワ',
    0x0C: 'ホ', 0x0D: 'ヘ', 0x0E: 'ー',
    0x11: 'タ', 0x12: 'テ', 0x13: 'イ', 0x14: 'ス', 0x15: 'カ',
    0x16: 'ン', 0x17: 'ナ', 0x18: 'ニ', 0x19: 'ラ', 0x1A: 'セ',
    0x1B: '゛', 0x1C: '゜',
    0x1E: 'チ', 0x1F: 'ト', 0x20: 'シ', 0x21: 'ハ', 0x22: 'キ',
    0x23: 'ク', 0x24: 'マ', 0x25: 'ノ', 0x26: 'リ', 0x27: 'レ',
    0x28: 'ケ', 0x29: 'ム',
    0x2A: 'ツ', 0x2B: 'サ', 0x2C: 'ソ', 0x2D: 'ヒ', 0x2E: 'コ',
    0x2F: 'ミ', 0x30: 'モ', 0x31: 'ネ', 0x32: 'ル', 0x33: 'メ',
    0x34: 'ロ',
  };

  // かな OFF + SHIFT 押下時に表示する記号 (X68000 JIS 配列)
  static const Map<int, String> _shiftLabels = {
    0x02: '!',  0x03: '"',  0x04: '#',  0x05: '\$', 0x06: '%',
    0x07: '&',  0x08: '\'', 0x09: '(',  0x0A: ')',
    0x0C: '=',  0x0D: '~',  0x0E: '|',
    0x31: '<',  0x32: '>',  0x33: '?',
  };

  // キーリピート (X68000 の SET REPEAT START / RATE コマンドで可変)
  // delay / interval は shared.repeatDelayMs / repeatIntervalMs を参照する。
  Timer? _repeatTimer;
  int? _repeatScancode;

  // REMOTE 連続発射用の専用タイマ。キーボード側のリピート (_repeatTimer) とは
  // 独立に動かす (X68000 SET REPEAT の影響を受けず、コマンド固有の Duration で
  // 回す)。シングルインスタンスで運用し、別の REMOTE-repeatable キーが押された
  // ら上書きする (キーボード _repeatTimer と同じモデル)。
  Timer? _remoteRepeatTimer;
  int? _remoteRepeatScancode;

  // リピートさせないキー (モディファイア / LED トグル系)
  //   0x5A: かな        0x5B: ローマ字    0x5C: コード入力
  //   0x5D: CAPS        0x5E: INS         0x5F: ひらがな   0x60: 全角
  //   0x70: SHIFT       0x71: CTRL        0x72: OPT.1      0x73: OPT.2
  static const Set<int> _noRepeatScancodes = {
    0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60,
    0x70, 0x71, 0x72, 0x73,
  };

  // 英字キー (A-Z) のスキャンコード集合。CAPS LED と SHIFT 押下の XOR で
  // キートップの大文字 / 小文字を切り替えるために使う。
  static const Set<int> _letterScancodes = {
    0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19, 0x1A, // Q-P
    0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26,       // A-L
    0x2A, 0x2B, 0x2C, 0x2D, 0x2E, 0x2F, 0x30,                   // Z-M
  };

  // ===========================================================================
  // SHIFT/OPT.2 + キーによる TV リモコン発射
  // ===========================================================================
  //
  // X68000 純正キーボードの仕様: SHIFT + テンキー/矢印/CLR で REMOTE 端子から
  // SHARP 12-bit リモコンコードを送出する。本体設定 (OPT2 EN, shared 経由で受信)
  // が有効なときは OPT.2 でも代用できる (SHIFT との OR、排他ではない)。
  // スキャンコード自体は X68000 にもパススルーされる (実機キーボードと同じ動き)。
  //
  // ホスト側でこの組み合わせを検出し、EMIT_REMOTE を firmware に送って REMOTE
  // 端子から発射してもらう。
  //
  // scancode → コマンド の対応表は DisplayControlCommand 側で一元管理しており、
  // ここでは byScancode() で引くだけ。割り当てが無いキーは何もしない。

  /// SHIFT (常時) または OPT.2 (OPT2 EN 受信済 & 有効) が現在押されているか。
  /// 仮想キーボードでは sticky 化された modifier も `_pressed` に含まれる。
  bool _remoteModifierHeld() {
    if (_pressed.contains(0x70)) return true; // SHIFT
    if (_pressed.contains(0x73) && widget.shared.displayOpt2Enabled) {
      return true; // OPT.2 (本体が OPT2 EN を有効化したとき限定)
    }
    return false;
  }

  /// 初期押下時。SHIFT/OPT.2 同時押しで対応する REMOTE コードを発射する。
  /// 現在のディスプレイ制御モード (X68000/X1) を `widget.shared.isX1Mode` で取得し、
  /// モード別の `DisplayControlCommand` 一覧から該当キーを引く。
  /// CTRL EN との関係は実機未検証だが、本機能は本体発の制御 (CTRL EN 対象) では
  /// なく純粋なキーボード側の発射なので、CTRL EN とは独立に動く想定。
  ///
  /// コマンドに `remoteRepeatInterval` が設定されていれば、押下中はその間隔で
  /// REMOTE を再発射し続ける専用 Timer をスケジュールする。
  void _maybeEmitRemoteOnPress(int scancode) {
    final cmd = DisplayControlCommand.byScancode(
      scancode,
      x1Mode: widget.shared.isX1Mode,
    );
    if (cmd == null) return;
    if (!_remoteModifierHeld()) return;
    widget.midi.emitRemote(cmd.code);
    _scheduleRemoteRepeat(scancode, cmd);
  }

  /// REMOTE 連続発射の Timer を仕掛ける。既存タイマがあれば差し替える
  /// (キーボード _repeatTimer と同じモデル: 直近に押されたキーが優位)。
  /// 押下中またはモディファイア解除時に自己キャンセルする。
  void _scheduleRemoteRepeat(int scancode, DisplayControlCommand cmd) {
    _remoteRepeatTimer?.cancel();
    _remoteRepeatTimer = null;
    _remoteRepeatScancode = null;
    final interval = cmd.remoteRepeatInterval;
    if (interval == null) return;
    _remoteRepeatScancode = scancode;
    _remoteRepeatTimer = Timer.periodic(interval, (_) {
      // スキャンコードが離された / モディファイアが外れた / 別キーが優位になった
      // のいずれかなら停止。
      if (_remoteRepeatScancode != scancode ||
          !_pressed.contains(scancode) ||
          !_remoteModifierHeld()) {
        _remoteRepeatTimer?.cancel();
        _remoteRepeatTimer = null;
        _remoteRepeatScancode = null;
        return;
      }
      widget.midi.emitRemote(cmd.code);
    });
  }

  /// 指定スキャンコードに紐づく REMOTE 連続発射タイマを停止する。
  /// 該当キーが現在の繰り返し対象でなければ何もしない。
  void _cancelRemoteRepeatFor(int scancode) {
    if (_remoteRepeatScancode == scancode) {
      _remoteRepeatTimer?.cancel();
      _remoteRepeatTimer = null;
      _remoteRepeatScancode = null;
    }
  }

  // 押下ポップアップの表示制御。短いタップでも一定時間は表示しておく
  static const Duration _popupMinShow = Duration(milliseconds: 250);
  // 押しっぱなしでも一定時間で自動消去する。吹き出しが隣接キーを覆い続けて
  // 同時押しの邪魔になるのを避けるため。
  static const Duration _popupAutoHide = Duration(milliseconds: 500);
  // 連打時に「一旦消えて再表示」して視覚的にカウントできるようにするための短い間
  static const Duration _popupBlinkGap = Duration(milliseconds: 30);
  final Map<int, Timer> _popupHideTimers = {};
  Timer? _popupShowTimer;
  // ポップアップは Overlay にエントリを差し込んで AppBar 含む最上層に描画する
  final Map<int, OverlayEntry> _popupOverlays = {};

  // LED 輝度に応じた減衰係数 (0b010101xx: xx=00 最も明るい, xx=11 最も暗い)
  // xx=00 → factor 1.0, xx=11 → factor 0.25
  static const List<double> _brightnessFactors = [1.0, 0.7, 0.45, 0.25];

  // ポップアップで使う基本ユニットサイズ (LayoutBuilder で更新)
  double _h = 0;

  @override
  void initState() {
    super.initState();
    // 横向き固定は外側の X68kKeyboardPage で済ませてある。
    // onTargetRx は page が握って shared に流すので body 側では関与しない。

    // AppBar の "全解除" ボタンから呼ばれるコールバックを登録。
    widget.stickyController.onReleaseAllRequested = _releaseAllStuck;
    // sticky 状態 / shared (LED / 輝度) が変わったらキー描画を更新する。
    widget.stickyController.addListener(_onSharedChanged);
    widget.shared.addListener(_onSharedChanged);

    // デスクトップ / 外付け物理キーボードからのキーイベントを購読する。
    // Focus を介さない全域ハンドラなので AppBar 操作中でもキーが拾える。
    HardwareKeyboard.instance.addHandler(_handlePhysicalKey);

    // 別アプリからのリモート入力 (protocol.dart の sub-id 0x02) も同じ経路へ流す。
    // macOS はフォーカスの無いアプリにキーイベントを配送しないため、実機の映像を
    // 表示する別アプリを見ながら操作する場合はこちらが唯一の入力経路になる。
    _remoteInputSub = widget.midi.onRemoteInput.listen(_handleRemoteInput);
  }

  StreamSubscription<RemoteInputEvent>? _remoteInputSub;

  /// リモート入力の物理キーを、ローカルの物理キーとまったく同じ扱いで処理する。
  ///
  /// 転送されてくる usage は Flutter の PhysicalKeyboardKey.usbHidUsage と同じ値
  /// なので、findKeyByCode() で復元すれば既存の _physicalKeyMap がそのまま使える。
  ///
  /// 制約: PC キーボードモードの記号横取り (_pcCharMap) は event.character に
  /// 依存しており、物理キーだけでは文字が決まらないため適用されない。リモート
  /// 入力は常に X68k 配列モード相当の解釈になる。
  void _handleRemoteInput(RemoteInputEvent ev) {
    switch (ev) {
      case RemoteReleaseAllEvent():
        // 転送元がフォーカスを失った / 切断された。押しっぱなしを残さない。
        for (final code in _pressed.toList()) {
          _physicalKeyUp(code);
        }
      case RemoteKeyEvent(:final usage, :final pressed):
        final key = PhysicalKeyboardKey.findKeyByCode(usage);
        if (key == null) return;
        final scancode = _physicalKeyMap[key];
        if (scancode == null) return;
        if (pressed) {
          _physicalKeyDown(scancode);
        } else {
          _physicalKeyUp(scancode);
        }
    }
  }

  void _onSharedChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _repeatTimer?.cancel();
    _remoteRepeatTimer?.cancel();
    _popupShowTimer?.cancel();
    for (final t in _popupHideTimers.values) {
      t.cancel();
    }
    _popupHideTimers.clear();
    for (final entry in _popupOverlays.values) {
      entry.remove();
    }
    _popupOverlays.clear();
    // 退場時に sticky で残っている分を全て NoteOff してから controller を切る。
    _releaseAllStuck();
    widget.stickyController.removeListener(_onSharedChanged);
    widget.stickyController.onReleaseAllRequested = null;
    widget.shared.removeListener(_onSharedChanged);
    HardwareKeyboard.instance.removeHandler(_handlePhysicalKey);
    _remoteInputSub?.cancel();
    super.dispose();
  }

  // ===========================================================================
  // Sticky (押しっぱなし) ロジック — デスクトップで複数キー同時押し相当を実現
  // ===========================================================================

  /// 指定キーを sticky にする (まだなければ press 状態も併せて作る)。
  void _stickKey(int code) {
    if (widget.stickyController.isStuck(code)) return;
    widget.stickyController.add(code);
    if (!_pressed.contains(code)) {
      _pressed.add(code);
      widget.midi.sendNoteOn(widget.channel, code, 127);
      HapticFeedback.lightImpact();
    }
    if (mounted) setState(() {});
  }

  /// 指定キーの sticky を解除して NoteOff も送る。
  void _unstickKey(int code) {
    if (!widget.stickyController.isStuck(code)) return;
    widget.stickyController.remove(code);
    if (_pressed.remove(code)) {
      widget.midi.sendNoteOff(widget.channel, code);
    }
    if (mounted) setState(() {});
  }

  /// AppBar の "全解除" から呼ばれる。
  void _releaseAllStuck() {
    final stuck = widget.stickyController.stuck;
    if (stuck.isEmpty) return;
    for (final code in stuck) {
      if (_pressed.remove(code)) {
        widget.midi.sendNoteOff(widget.channel, code);
      }
    }
    widget.stickyController.clear();
    if (mounted) setState(() {});
  }

  /// 左クリック / タップ時の振り分け。
  ///   - kind == mouse かつ stuck   : 解除のみ (押下は発生させない)
  ///   - kind == mouse かつ sticky 対象 modifier : 自動 sticky
  ///   - それ以外 : 通常の momentary press (タッチ動作互換)
  /// 「sticky 化または解除されたのでこのタップは release を発火させない」場合
  /// に true を返す。
  bool _handleKeyDown(int code, TapDownDetails details, BuildContext keyCtx,
      List<String> labels) {
    if (details.kind == PointerDeviceKind.mouse) {
      if (widget.stickyController.isStuck(code)) {
        _unstickKey(code);
        return true;
      }
      if (_stickyModifierScancodes.contains(code)) {
        _stickKey(code);
        return true;
      }
    }
    _press(code, keyCtx, labels);
    return false;
  }

  /// 右クリック (二次タップ) は任意キーの sticky を toggle する。
  void _handleSecondaryTap(int code) {
    if (widget.stickyController.isStuck(code)) {
      _unstickKey(code);
    } else {
      _stickKey(code);
    }
  }

  // ===========================================================================
  // 物理キーボード直接入力
  // ===========================================================================
  //
  // PhysicalKeyboardKey → X68000 スキャンコード のマッピング。
  // 物理位置 (USB HID usage) ベースなので、OS / 配列 (JIS/US) に依らず一意。
  // X68000 自体が JIS 配列なので、JIS 物理キーボードを使えば刻印そのままで
  // 打てる。US 物理キーボードの場合は「P の右」が `[` 刻印でも X68k では `@`
  // になる、といった配置ズレが発生するが、これは PC キーボードモード (将来
  // 実装予定) で文字基準マッピングを選ぶことで解消する想定。
  //
  // 履歴: logicalKey ベースだと OS ごとに JIS の解釈が異なり (macOS は文字
  // 基準、Windows は VK code を US 配列で文字化) Windows で `:@^_` が
  // 打てない / 別キーが発火する問題があった。physicalKey に統一して解決。
  static final Map<PhysicalKeyboardKey, int> _physicalKeyMap = {
    // 文字キー
    PhysicalKeyboardKey.keyA: 0x1E, PhysicalKeyboardKey.keyB: 0x2E,
    PhysicalKeyboardKey.keyC: 0x2C, PhysicalKeyboardKey.keyD: 0x20,
    PhysicalKeyboardKey.keyE: 0x13, PhysicalKeyboardKey.keyF: 0x21,
    PhysicalKeyboardKey.keyG: 0x22, PhysicalKeyboardKey.keyH: 0x23,
    PhysicalKeyboardKey.keyI: 0x18, PhysicalKeyboardKey.keyJ: 0x24,
    PhysicalKeyboardKey.keyK: 0x25, PhysicalKeyboardKey.keyL: 0x26,
    PhysicalKeyboardKey.keyM: 0x30, PhysicalKeyboardKey.keyN: 0x2F,
    PhysicalKeyboardKey.keyO: 0x19, PhysicalKeyboardKey.keyP: 0x1A,
    PhysicalKeyboardKey.keyQ: 0x11, PhysicalKeyboardKey.keyR: 0x14,
    PhysicalKeyboardKey.keyS: 0x1F, PhysicalKeyboardKey.keyT: 0x15,
    PhysicalKeyboardKey.keyU: 0x17, PhysicalKeyboardKey.keyV: 0x2D,
    PhysicalKeyboardKey.keyW: 0x12, PhysicalKeyboardKey.keyX: 0x2B,
    PhysicalKeyboardKey.keyY: 0x16, PhysicalKeyboardKey.keyZ: 0x2A,
    // 数字キー
    PhysicalKeyboardKey.digit1: 0x02, PhysicalKeyboardKey.digit2: 0x03,
    PhysicalKeyboardKey.digit3: 0x04, PhysicalKeyboardKey.digit4: 0x05,
    PhysicalKeyboardKey.digit5: 0x06, PhysicalKeyboardKey.digit6: 0x07,
    PhysicalKeyboardKey.digit7: 0x08, PhysicalKeyboardKey.digit8: 0x09,
    PhysicalKeyboardKey.digit9: 0x0A, PhysicalKeyboardKey.digit0: 0x0B,
    // 制御キー
    PhysicalKeyboardKey.escape: 0x01,
    PhysicalKeyboardKey.backspace: 0x0F,
    PhysicalKeyboardKey.tab: 0x10,
    PhysicalKeyboardKey.enter: 0x1D,
    PhysicalKeyboardKey.space: 0x35,
    // 矢印
    PhysicalKeyboardKey.arrowUp: 0x3C,
    PhysicalKeyboardKey.arrowDown: 0x3E,
    PhysicalKeyboardKey.arrowLeft: 0x3B,
    PhysicalKeyboardKey.arrowRight: 0x3D,
    // モディファイア (左右どちらも同じ X68k キーに割り当て)
    PhysicalKeyboardKey.shiftLeft: 0x70,
    PhysicalKeyboardKey.shiftRight: 0x70,
    PhysicalKeyboardKey.controlLeft: 0x71,
    PhysicalKeyboardKey.controlRight: 0x71,
    PhysicalKeyboardKey.altLeft: 0x72,  // OPT.1
    PhysicalKeyboardKey.altRight: 0x73, // OPT.2
    // ファンクションキー
    PhysicalKeyboardKey.f1: 0x63, PhysicalKeyboardKey.f2: 0x64,
    PhysicalKeyboardKey.f3: 0x65, PhysicalKeyboardKey.f4: 0x66,
    PhysicalKeyboardKey.f5: 0x67, PhysicalKeyboardKey.f6: 0x68,
    PhysicalKeyboardKey.f7: 0x69, PhysicalKeyboardKey.f8: 0x6A,
    PhysicalKeyboardKey.f9: 0x6B, PhysicalKeyboardKey.f10: 0x6C,
    // 編集 / ナビゲーション
    PhysicalKeyboardKey.home: 0x36,
    PhysicalKeyboardKey.delete: 0x37,
    PhysicalKeyboardKey.insert: 0x5E,
    PhysicalKeyboardKey.pageUp: 0x38,    // ROLL UP
    PhysicalKeyboardKey.pageDown: 0x39,  // ROLL DOWN
    PhysicalKeyboardKey.capsLock: 0x5D,
    // 記号 (JIS 配列の物理位置を真として X68k スキャンコードへ対応付け)。
    // JIS 物理キーボードなら刻印通りに打てる。US 物理キーボードでは刻印が
    // ずれる (例: US の `[{` キー = X68k の `@` キー) ことに注意。
    PhysicalKeyboardKey.minus: 0x0C,         // JIS `-=`     US `-_`
    PhysicalKeyboardKey.equal: 0x0D,         // JIS `^~`     US `=+`
    PhysicalKeyboardKey.intlYen: 0x0E,       // JIS `¥|`     (US には無い)
    PhysicalKeyboardKey.bracketLeft: 0x1B,   // JIS `@``     US `[{`
    PhysicalKeyboardKey.bracketRight: 0x1C,  // JIS `[{`     US `]}`
    PhysicalKeyboardKey.semicolon: 0x27,     // JIS `;+`     US `;:`
    PhysicalKeyboardKey.quote: 0x28,         // JIS `:*`     US `'"`
    PhysicalKeyboardKey.backslash: 0x29,     // JIS `]}`     US `\|`
    PhysicalKeyboardKey.comma: 0x31,
    PhysicalKeyboardKey.period: 0x32,
    PhysicalKeyboardKey.slash: 0x33,
    PhysicalKeyboardKey.intlRo: 0x34,        // JIS `\_`     (US には無い)
    // テンキー (numpad)
    PhysicalKeyboardKey.numpad0: 0x4F,
    PhysicalKeyboardKey.numpad1: 0x4B,
    PhysicalKeyboardKey.numpad2: 0x4C,
    PhysicalKeyboardKey.numpad3: 0x4D,
    PhysicalKeyboardKey.numpad4: 0x47,
    PhysicalKeyboardKey.numpad5: 0x48,
    PhysicalKeyboardKey.numpad6: 0x49,
    PhysicalKeyboardKey.numpad7: 0x43,
    PhysicalKeyboardKey.numpad8: 0x44,
    PhysicalKeyboardKey.numpad9: 0x45,
    PhysicalKeyboardKey.numpadDecimal: 0x51,
    PhysicalKeyboardKey.numpadComma: 0x50,
    PhysicalKeyboardKey.numpadEnter: 0x4E,
    PhysicalKeyboardKey.numpadAdd: 0x46,
    PhysicalKeyboardKey.numpadSubtract: 0x42,
    PhysicalKeyboardKey.numpadMultiply: 0x41,
    PhysicalKeyboardKey.numpadDivide: 0x40,
    PhysicalKeyboardKey.numpadEqual: 0x4A,
  };

  // ---------------------------------------------------------------------------
  // PC キーボードモード用: 文字 → (X68k スキャンコード, SHIFT 要否) テーブル。
  // ---------------------------------------------------------------------------
  // 含めるのは X68k JIS 配列で「位置が US と違う」記号キー類だけ。英数字は
  // 物理位置で完全に一致するので物理マップに任せる方が auto-repeat 周りで素直。
  //
  // US 物理キーボードのユーザが PC モードに切り替えると、例えば Shift+2 で
  // 出る `@` 文字を、SHIFT を一瞬上げて X68k の `@` キー (0x1B) にタップで
  // 流し込めるようになる。
  static const Map<String, (int, bool)> _pcCharMap = {
    // unshifted on X68k JIS
    '@': (0x1B, false),
    ':': (0x28, false),
    '^': (0x0D, false),
    '[': (0x1C, false),
    ']': (0x29, false),
    ';': (0x27, false),
    '-': (0x0C, false),
    ',': (0x31, false),
    '.': (0x32, false),
    '/': (0x33, false),
    '\\': (0x34, false),   // ろキー (X68 0x34 unshifted = `\`)
    '¥': (0x0E, false),
    // shifted on X68k JIS
    '_': (0x34, true),
    '!': (0x02, true),
    '"': (0x03, true),
    '#': (0x04, true),
    '\$': (0x05, true),
    '%': (0x06, true),
    '&': (0x07, true),
    '\'': (0x08, true),
    '(': (0x09, true),
    ')': (0x0A, true),
    '=': (0x0C, true),
    '~': (0x0D, true),
    '|': (0x0E, true),
    '`': (0x1B, true),
    '{': (0x1C, true),
    '+': (0x27, true),
    '*': (0x28, true),
    '}': (0x29, true),
    '<': (0x31, true),
    '>': (0x32, true),
    '?': (0x33, true),
  };

  // PC キーボードモードで「KeyDown を文字オーバーライドで処理した」物理キー集合。
  // 同じ物理キーの KeyRepeat / KeyUp はここを見て pass-through を抑止する。
  final Set<PhysicalKeyboardKey> _pcOverriddenKeys = {};

  /// PC キーボードモード: X68k 上の SHIFT 状態を要求方向に一瞬倒した状態で
  /// 対象キーを単発タップし、SHIFT を元に戻す。`_pressed` には触らないので
  /// 物理 SHIFT のミラー (X68k 配列モード共通の経路) を壊さない。
  void _emitPcSymbolTap(String ch) {
    final entry = _pcCharMap[ch];
    if (entry == null) return;
    final code = entry.$1;
    final requiresShift = entry.$2;

    final x68kShiftDown = _pressed.contains(0x70);
    final shiftAdjust = x68kShiftDown != requiresShift;

    if (shiftAdjust) {
      if (requiresShift) {
        widget.midi.sendNoteOn(widget.channel, 0x70, 127);
      } else {
        widget.midi.sendNoteOff(widget.channel, 0x70);
      }
    }
    widget.midi.sendNoteOn(widget.channel, code, 127);
    widget.midi.sendNoteOff(widget.channel, code);
    if (shiftAdjust) {
      if (requiresShift) {
        widget.midi.sendNoteOff(widget.channel, 0x70);
      } else {
        widget.midi.sendNoteOn(widget.channel, 0x70, 127);
      }
    }
  }

  /// HardwareKeyboard コールバック。マップにあるキーだけハンドルし、それ以外は
  /// false を返して他のリスナ (OS ショートカット等) に処理を委譲する。
  bool _handlePhysicalKey(KeyEvent event) {
    // 物理キーは表示中の画面 (キーボード / ジョイスティック) に関わらず X68k へ送る。
    // このハンドラは HardwareKeyboard のグローバル購読で、Standard モードの body が
    // 生存している間だけ登録される (ライン入力モードでは未登録なので TextField 入力を
    // 邪魔しない)。Combined セッションでは Standard body が常時生存するため、
    // ジョイスティック画面表示中でも物理キーボードがそのまま効く。
    // --- PC キーボードモード: 記号系を character ベースで横取り ---
    // KeyDown は mode が ON のときだけ判定する。一度 override に乗った物理キー
    // は KeyRepeat / KeyUp も同じ経路で完結させたいので、モード切替を跨いでも
    // 整合するように set ベースで管理する。
    if (event is KeyDownEvent && widget.pcKeyboardMode) {
      final ch = event.character;
      if (ch != null && _pcCharMap.containsKey(ch)) {
        _pcOverriddenKeys.add(event.physicalKey);
        _emitPcSymbolTap(ch);
        return true;
      }
    }
    if (event is KeyRepeatEvent &&
        _pcOverriddenKeys.contains(event.physicalKey)) {
      final ch = event.character;
      if (ch != null && _pcCharMap.containsKey(ch)) {
        _emitPcSymbolTap(ch);
      }
      return true;
    }
    if (event is KeyUpEvent &&
        _pcOverriddenKeys.remove(event.physicalKey)) {
      return true;
    }

    // --- 通常 (X68k 配列モード) 経路: 物理位置 → X68k スキャンコード ---
    final scancode = _physicalKeyMap[event.physicalKey];
    if (scancode == null) {
      // マッピング外のキー。修飾キー併用 (Cmd/Ctrl/Alt) の OS ショートカットは
      // OS に委ねる (return false)。それ以外の単キーは consume して NSBeep を抑止する
      // (キーボード画面では body の Focus が消費するが、ジョイスティック画面では
      //  この経路が唯一の消費者になる)。
      final hw = HardwareKeyboard.instance;
      if (hw.isMetaPressed || hw.isControlPressed || hw.isAltPressed) {
        return false;
      }
      return true;
    }

    if (event is KeyDownEvent) {
      _physicalKeyDown(scancode);
      return true;
    }
    if (event is KeyUpEvent) {
      _physicalKeyUp(scancode);
      return true;
    }
    // OS のオートリピートはファームが repeat 管理するため NoteOn 重発は不要。
    // ただし return false にすると macOS が「未処理キー」と見なして NSBeep を
    // 鳴らすので、イベント自体は consume (return true) して握りつぶす。
    if (event is KeyRepeatEvent) {
      return true;
    }
    return false;
  }

  void _physicalKeyDown(int code) {
    // 既に押されている (sticky 等) なら二重 NoteOn を避ける
    if (_pressed.contains(code)) return;
    _pressed.add(code);
    widget.midi.sendNoteOn(widget.channel, code, 127);
    // SHIFT/OPT.2 同時押しなら REMOTE 発射 (スキャンコードはそのまま X68000 にも流す)
    _maybeEmitRemoteOnPress(code);
    // リピートは画面タップと同じくアプリ側 Timer で実装する (ファームの
    // SET REPEAT で配られた delay/interval をアプリが受け取り、ここで再送する)。
    // OS の KeyRepeatEvent は _handlePhysicalKey 側で消費しているので、
    // この Timer 由来の NoteOn だけが流れる。
    if (!_noRepeatScancodes.contains(code)) {
      _scheduleRepeat(code);
    }
    if (mounted) setState(() {});
  }

  void _physicalKeyUp(int code) {
    // sticky 中は物理キーの release で解除しない (画面上の sticky を尊重)
    if (widget.stickyController.isStuck(code)) return;
    if (_pressed.remove(code)) {
      if (_repeatScancode == code) {
        _repeatTimer?.cancel();
        _repeatScancode = null;
      }
      _cancelRemoteRepeatFor(code);
      widget.midi.sendNoteOff(widget.channel, code);
      if (mounted) setState(() {});
    }
  }

  // ターゲット機からの生バイト処理は X68kKeyboardPage が一括して shared に
  // 流す方式に変更したため、body 内の _handleTargetRx は撤廃。
  // LED 状態 / 輝度 / リピート設定は widget.shared から参照する。

  void _press(int code, BuildContext keyCtx, List<String> labels) {
    if (_pressed.add(code)) {
      widget.midi.sendNoteOn(widget.channel, code, 127);
      HapticFeedback.lightImpact();
      // SHIFT/OPT.2 同時押しなら REMOTE 発射 (スキャンコードはそのまま X68000 にも流す)
      _maybeEmitRemoteOnPress(code);
      if (!_noRepeatScancodes.contains(code)) {
        _scheduleRepeat(code);
      }
    }
    // 別キー/同キーのいずれの再押下でも、まず既存ポップアップを即時消す
    // (連打時に "ポン・ポン" と分かれて見えるように)
    _popupShowTimer?.cancel();
    for (final t in _popupHideTimers.values) {
      t.cancel();
    }
    _popupHideTimers.clear();
    _hideAllPopupOverlays();
    setState(() {});

    // ごく短い間ブランクにしてから今回の押下キーを表示。表示後は _popupAutoHide
    // 経過で自動的に消す (押しっぱなしでも消える)。release ハンドラ側がより早い
    // hide タイマーに差し替えるケースもある。
    _popupShowTimer = Timer(_popupBlinkGap, () {
      if (!mounted) return;
      _showPopupOverlay(code, keyCtx, labels);
      _popupHideTimers.remove(code)?.cancel();
      _popupHideTimers[code] = Timer(_popupAutoHide, () {
        if (!mounted) return;
        _popupOverlays.remove(code)?.remove();
        _popupHideTimers.remove(code);
      });
    });
  }

  void _release(int code) {
    // sticky 中のキーは指を離しても release しない (押しっぱなしを維持)。
    if (widget.stickyController.isStuck(code)) {
      return;
    }
    if (_pressed.remove(code)) {
      if (_repeatScancode == code) {
        _repeatTimer?.cancel();
        _repeatScancode = null;
      }
      _cancelRemoteRepeatFor(code);
      widget.midi.sendNoteOff(widget.channel, code);
    }
    // 短いタップでも吹き出しが視認できるよう、最低表示時間後に消す
    _popupHideTimers.remove(code)?.cancel();
    _popupHideTimers[code] = Timer(_popupMinShow, () {
      if (!mounted) return;
      _popupOverlays.remove(code)?.remove();
      _popupHideTimers.remove(code);
    });
    setState(() {});
  }

  void _hideAllPopupOverlays() {
    for (final entry in _popupOverlays.values) {
      entry.remove();
    }
    _popupOverlays.clear();
  }

  // OverlayEntry を挿入してキー上方に吹き出しを描画する。
  // Overlay は Scaffold (AppBar 含む) の上に描画されるので、最上段キーでも隠れない。
  void _showPopupOverlay(int scancode, BuildContext keyCtx, List<String> labels) {
    if (!mounted) return;
    final box = keyCtx.findRenderObject();
    if (box is! RenderBox || !box.attached) return;

    final origin = box.localToGlobal(Offset.zero);
    final keySize = box.size;

    final popupH = (_h > 0 ? _h : 40) * 1.1;
    final popupW = (keySize.width * 1.2).clamp(popupH, double.infinity);

    final left = origin.dx + (keySize.width - popupW) / 2;
    final top = origin.dy - popupH - 6;

    final entry = OverlayEntry(
      builder: (ctx) => Positioned(
        left: left,
        top: top,
        width: popupW,
        height: popupH,
        child: IgnorePointer(child: _popupContent(labels, popupW, popupH)),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(entry);
    _popupOverlays[scancode] = entry;
  }

  Widget _popupContent(List<String> labels, double w, double h) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF3399FF),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white, width: 1.5),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 6, offset: Offset(0, 3)),
        ],
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: labels
              .map((s) => Text(
                    s,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: _autoFontSize(s, w, h) * 1.2,
                      height: 1.0,
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }

  // 押下から shared.repeatDelayMs 経過したらリピート開始
  void _scheduleRepeat(int code) {
    _repeatTimer?.cancel();
    _repeatScancode = code;
    _repeatTimer =
        Timer(Duration(milliseconds: widget.shared.repeatDelayMs), () {
      if (!_pressed.contains(code)) return;
      _startRepeating(code);
    });
  }

  // shared.repeatIntervalMs 間隔で Note On を撃ち続ける (firmware 側は make コードを再送)
  // REMOTE 連続発射はキーボード側ペースとは独立 (専用 _remoteRepeatTimer) なので
  // ここでは扱わない。
  void _startRepeating(int code) {
    _repeatTimer = Timer.periodic(
      Duration(milliseconds: widget.shared.repeatIntervalMs),
      (_) {
        if (!_pressed.contains(code)) {
          _repeatTimer?.cancel();
          _repeatScancode = null;
          return;
        }
        widget.midi.sendNoteOn(widget.channel, code, 127);
        // リピートのたびに軽い触覚フィードバック
        HapticFeedback.selectionClick();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasMouse = widget.mouseChannel != null;
    // 背景色は ModeScaffold ではなく body 側で持つ (キーボードページの黒地)。
    return Container(
      color: const Color(0xFF1a1a1a),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final showTrackpad = hasMouse && widget.trackpadVisible;
            if (!showTrackpad) {
              // トラックパッドが無い (= マウス未搭載 or 非表示) ときは、空いた縦領域を
              // キーボードが埋めるように h を縦方向に伸ばす。
              return _buildKeyboard(constraints, fillHeight: true);
            }
            // トラックパッドの最小高 (これ以上は確保する)
            const trackpadMinH = 100.0;
            // キーボードに与えられる最大高さ
            final maxKbH =
                (constraints.maxHeight - trackpadMinH).clamp(0.0, double.infinity);
            // キーボードは幅でも高さでもはみ出さないよう u を計算
            final keyboard = _buildKeyboard(BoxConstraints(
              maxWidth: constraints.maxWidth,
              maxHeight: maxKbH,
            ));
            return Column(
              children: [
                keyboard,
                Expanded(
                  child: _TrackpadArea(
                    midi: widget.midi,
                    channel: widget.mouseChannel!,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  // レイアウト定数 (unit 単位)
  //   mainArea (16) + gap (0.3) + cursorArea (3) + gap (0.3) + numpadArea (4) = 23.6
  //   テンキー非表示時:  mainArea (16) + gap (0.3) + cursorArea (3)            = 19.3
  static const double _mainAreaW = 16.0;
  static const double _cursorAreaW = 3.0;
  static const double _numpadAreaW = 4.0;
  static const double _gap = 0.3;

  double get _totalW => widget.numpadVisible
      ? _mainAreaW + _gap + _cursorAreaW + _gap + _numpadAreaW
      : _mainAreaW + _gap + _cursorAreaW;

  // キーボードの行構成: function row + 4 main rows + bottom row = 6 行 + fnGap(=0.15h)
  // 合計コンテンツ高 = 6.15 * h = 6.15 * 0.95 * u = ~5.8425 * u
  // パディング (innerPad * 2 = 16) を加えて keyboardH = 5.8425*u + 16
  static const double _rowsPerH = 6.15;
  static const double _hPerU = 0.95;

  Widget _buildKeyboard(BoxConstraints constraints, {bool fillHeight = false}) {
    // 各キーは declared width 内にパディングを内包するため、unit 計算は単純な分割で OK
    final outerPadding = 16.0;
    final innerPad = 8.0;
    final innerPadTotal = innerPad * 2;

    final availableW = constraints.maxWidth - outerPadding;
    final uByWidth = availableW / _totalW;
    // 高さ制約があれば、それを超えないように u を制限する
    double u = uByWidth;
    if (constraints.maxHeight.isFinite) {
      final availableH = constraints.maxHeight - innerPadTotal;
      if (availableH > 0) {
        final uByHeight = availableH / (_rowsPerH * _hPerU);
        if (uByHeight < u) u = uByHeight;
      }
    }
    double h = u * _hPerU;
    // fillHeight=true のときは、u (キー幅) が width で律速されて空いた縦余白を、
    // h (行高) を独立に伸ばして埋める。キーがやや縦長になるが、幅を保ったまま
    // 画面いっぱいまで広がる挙動になる。
    if (fillHeight && constraints.maxHeight.isFinite) {
      final fillH = (constraints.maxHeight - innerPadTotal) / _rowsPerH;
      if (fillH > h) h = fillH;
    }
    _h = h;  // ポップアップサイズ計算用に保存

    // 縦長キー (Return / numpad ENTER) を Stack で重ねるための位置計算
    // Y 位置: function row(h) + gap(0.15h) + 累積行
    final fnRowH = h;
    final fnGap = h * 0.15;
    final yRow1 = innerPad + fnRowH + fnGap;
    final yRow2 = yRow1 + h;
    final yRow3 = yRow2 + h;
    final yRow4 = yRow3 + h;

    // X 位置: メインエリア内
    // 行 2 main: TAB(1.6) + Q-P(10) + @(1) + [(1) = 13.6u
    // 行 3 main: CTRL(1.6) + A-L(9) + ;:](3) = 13.6u
    // Return キーは 13.6u から 15.5u (BS の右端) まで → 幅 1.9u
    final xReturn = innerPad + u * 13.6;
    final returnW = 1.9;
    // 行 4-5 numpad ENTER は numpad 領域の最右
    final xNumpadEnter = innerPad + u * (_mainAreaW + _gap + _cursorAreaW + _gap + 3);

    // カーソル ←/→ をクロス配置で行 3-4 の中央に置く
    final xCursorAreaStart = innerPad + u * (_mainAreaW + _gap);
    final xLeftCursor = xCursorAreaStart;
    final xRightCursor = xCursorAreaStart + u * 2;
    final yLeftRightCursor = yRow3 + h * 0.5;  // ↑ と ↓ の中間

    return Stack(
      clipBehavior: Clip.none,
      children: [
          Padding(
            padding: EdgeInsets.all(innerPad),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildFunctionRow(u, h),
                SizedBox(height: fnGap),
                _buildMainAreaRow1(u, h),
                _buildMainAreaRow2(u, h),
                _buildMainAreaRow3(u, h),
                _buildMainAreaRow4(u, h),
                _buildBottomRow(u, h),
              ],
            ),
          ),
          // Return キー (縦 2 段、幅 1.9u で BS と右端揃え)
          Positioned(
            left: xReturn,
            top: yRow2,
            child: SizedBox(
              width: u * returnW,
              height: h * 2,
              child: _keyMulti(['↵'], 0x1D, u * returnW, h * 2),
            ),
          ),
          // ←: カーソル列の左、行 3 と 4 の中間
          Positioned(
            left: xLeftCursor,
            top: yLeftRightCursor,
            child: SizedBox(
              width: u, height: h,
              child: _key('←', 0x3B, u, h),
            ),
          ),
          // →: カーソル列の右
          Positioned(
            left: xRightCursor,
            top: yLeftRightCursor,
            child: SizedBox(
              width: u, height: h,
              child: _key('→', 0x3D, u, h),
            ),
          ),
          // テンキー ENTER (縦 2 段) — テンキー表示時のみ
          if (widget.numpadVisible)
            Positioned(
              left: xNumpadEnter,
              top: yRow4,
              child: SizedBox(
                width: u,
                height: h * 2,
                child: _keyMulti(['ENTER'], 0x4E, u, h * 2),
              ),
            ),
      ],
    );
  }

  // BREAK COPY F1-F10 | かな ローマ字 コード入力 | CAPS 記号入力 登録 HELP
  Widget _buildFunctionRow(double u, double h) {
    // F1-F10 は幅 1.27u に拡張して、F10 の右端が下の段の BS / Return キーの
    // 右端 (15.5u) と揃うようにする。
    //   main = BREAK(1.2) + COPY(1.2) + gap(0.2) + F1-F5(5*1.27) + gap(0.2) + F6-F10(5*1.27)
    //        = 1.2 + 1.2 + 0.2 + 6.35 + 0.2 + 6.35 = 15.5u
    // cursor = 3u (かな + ローマ字 + コード入力)
    // numpad = 4u (CAPS + 記号入力 + 登録 + HELP)
    const fKeyW = 1.27;
    return _row3(
      u: u, h: h,
      main: [
        _key('BREAK', 0x61, u * 1.2, h),
        _key('COPY', 0x62, u * 1.2, h),
        SizedBox(width: u * 0.2),
        _key('F1', 0x63, u * fKeyW, h), _key('F2', 0x64, u * fKeyW, h),
        _key('F3', 0x65, u * fKeyW, h), _key('F4', 0x66, u * fKeyW, h),
        _key('F5', 0x67, u * fKeyW, h),
        SizedBox(width: u * 0.2),
        _key('F6', 0x68, u * fKeyW, h), _key('F7', 0x69, u * fKeyW, h),
        _key('F8', 0x6A, u * fKeyW, h), _key('F9', 0x6B, u * fKeyW, h),
        _key('F10', 0x6C, u * fKeyW, h),
      ],
      mainSumU: 1.2 + 1.2 + 0.2 + 5 * fKeyW + 0.2 + 5 * fKeyW,
      cursor: [
        _keyMulti(['かな'], 0x5A, u, h),
        _keyMulti(['ローマ字'], 0x5B, u, h),
        _keyMulti(['コード入力'], 0x5C, u, h),
      ],
      cursorSumU: 3,
      numpad: [
        _key('CAPS', 0x5D, u, h),
        _keyMulti(['記号', '入力'], 0x52, u, h),
        _keyMulti(['登録'], 0x53, u, h),
        _key('HELP', 0x54, u, h),
      ],
      numpadSumU: 4,
    );
  }

  // 行を「main + gap + cursor + gap + numpad」形式で組み立てる
  // widget.numpadVisible=false のときは numpad 部分を完全に省略する
  Widget _row3({
    required double u,
    required double h,
    required List<Widget> main,
    required double mainSumU,    // main 内のキー幅合計 (unit)
    required List<Widget> cursor,
    required double cursorSumU,  // cursor 内のキー幅合計 (unit)
    required List<Widget> numpad,
    required double numpadSumU,
  }) {
    return Row(
      children: [
        ...main,
        SizedBox(width: u * (_mainAreaW - mainSumU)),
        SizedBox(width: u * _gap),
        ...cursor,
        SizedBox(width: u * (_cursorAreaW - cursorSumU)),
        if (widget.numpadVisible) ...[
          SizedBox(width: u * _gap),
          ...numpad,
          SizedBox(width: u * (_numpadAreaW - numpadSumU)),
        ],
      ],
    );
  }

  // 数字行: ESC 1234567890-^¥ BS  | HOME INS DEL  | CLR / * -
  Widget _buildMainAreaRow1(double u, double h) {
    return _row3(
      u: u, h: h,
      main: [
        _key('ESC', 0x01, u * 1.1, h),
        _key('1', 0x02, u, h), _key('2', 0x03, u, h), _key('3', 0x04, u, h),
        _key('4', 0x05, u, h), _key('5', 0x06, u, h), _key('6', 0x07, u, h),
        _key('7', 0x08, u, h), _key('8', 0x09, u, h), _key('9', 0x0A, u, h),
        _key('0', 0x0B, u, h),
        _key('-', 0x0C, u, h), _key('^', 0x0D, u, h), _key('¥', 0x0E, u, h),
        _key('BS', 0x0F, u * 1.4, h),
      ],
      mainSumU: 1.1 + 13 + 1.4,
      cursor: [
        _key('HOME', 0x36, u, h),
        _key('INS', 0x5E, u, h),
        _key('DEL', 0x37, u, h),
      ],
      cursorSumU: 3,
      numpad: [
        _key('CLR', 0x3F, u, h),
        _key('/', 0x40, u, h),
        _key('*', 0x41, u, h),
        _key('-', 0x42, u, h),
      ],
      numpadSumU: 4,
    );
  }

  // TAB QWERTYUIOP @ [ + (Return は Stack で 2段) | ROLL UP, ROLL DOWN, UNDO | 7 8 9 +
  Widget _buildMainAreaRow2(double u, double h) {
    return _row3(
      u: u, h: h,
      main: [
        _key('TAB', 0x10, u * 1.6, h),
        _key('Q', 0x11, u, h), _key('W', 0x12, u, h), _key('E', 0x13, u, h),
        _key('R', 0x14, u, h), _key('T', 0x15, u, h), _key('Y', 0x16, u, h),
        _key('U', 0x17, u, h), _key('I', 0x18, u, h), _key('O', 0x19, u, h),
        _key('P', 0x1A, u, h),
        _key('@', 0x1B, u, h), _key('[', 0x1C, u, h),
        // Return キーは Stack で重ねる (位置 13.6u, 幅 1.9u, 縦 2 段)
        SizedBox(width: u * 1.9),
      ],
      mainSumU: 1.6 + 10 + 1 + 1 + 1.9,
      cursor: [
        _keyMulti(['ROLL', 'UP'], 0x38, u, h),
        _keyMulti(['ROLL', 'DOWN'], 0x39, u, h),
        _key('UNDO', 0x3A, u, h),
      ],
      cursorSumU: 3,
      numpad: [
        _key('7', 0x43, u, h), _key('8', 0x44, u, h), _key('9', 0x45, u, h),
        _key('+', 0x46, u, h),
      ],
      numpadSumU: 4,
    );
  }

  // CTRL ASDFGHJKL ; : ] (Return wrap は Stack) | (空) ↑ (空) | 4 5 6 =
  // ←/→ は行 3-4 の中央に Stack 配置するためここでは空欄を確保するだけ
  Widget _buildMainAreaRow3(double u, double h) {
    return _row3(
      u: u, h: h,
      main: [
        _key('CTRL', 0x71, u * 1.6, h),
        _key('A', 0x1E, u, h), _key('S', 0x1F, u, h), _key('D', 0x20, u, h),
        _key('F', 0x21, u, h), _key('G', 0x22, u, h), _key('H', 0x23, u, h),
        _key('J', 0x24, u, h), _key('K', 0x25, u, h), _key('L', 0x26, u, h),
        _key(';', 0x27, u, h), _key(':', 0x28, u, h), _key(']', 0x29, u, h),
        // Return が Stack で覆う領域 (1.9u 分)
        SizedBox(width: u * 1.9),
      ],
      mainSumU: 1.6 + 9 + 3 + 1.9,
      cursor: [
        // ↑ を中央に、左右は ←/→ を Stack で重ねるため空欄
        SizedBox(width: u),
        _key('↑', 0x3C, u, h),
        SizedBox(width: u),
      ],
      cursorSumU: 3,
      numpad: [
        _key('4', 0x47, u, h), _key('5', 0x48, u, h), _key('6', 0x49, u, h),
        _key('=', 0x4A, u, h),
      ],
      numpadSumU: 4,
    );
  }

  // SHIFT ZXCVBNM , . / _ SHIFT | (空) ↓ (空) | 1 2 3 (ENTER は Stack で 2段)
  Widget _buildMainAreaRow4(double u, double h) {
    return _row3(
      u: u, h: h,
      main: [
        _key('SHIFT', 0x70, u * 2.1, h),
        _key('Z', 0x2A, u, h), _key('X', 0x2B, u, h), _key('C', 0x2C, u, h),
        _key('V', 0x2D, u, h), _key('B', 0x2E, u, h), _key('N', 0x2F, u, h),
        _key('M', 0x30, u, h),
        _key(',', 0x31, u, h), _key('.', 0x32, u, h), _key('/', 0x33, u, h),
        _key('_', 0x34, u, h),
        _key('SHIFT', 0x70, u * 2.4, h),
      ],
      mainSumU: 2.1 + 7 + 4 + 2.4,
      cursor: [
        // ↓ を中央に
        SizedBox(width: u),
        _key('↓', 0x3E, u, h),
        SizedBox(width: u),
      ],
      cursorSumU: 3,
      numpad: [
        _key('1', 0x4B, u, h), _key('2', 0x4C, u, h), _key('3', 0x4D, u, h),
        // ENTER は Stack で重ねる
        SizedBox(width: u),
      ],
      numpadSumU: 4,
    );
  }

  // ひらがな XF1 XF2 SPACE XF3 XF4 XF5 全角 | OPT.1(1.5u) OPT.2(1.5u) | 0(2u) , . (ENTER は Stack)
  Widget _buildBottomRow(double u, double h) {
    return _row3(
      u: u, h: h,
      main: [
        _keyMulti(['ひらがな'], 0x5F, u * 1.5, h),
        _key('XF1', 0x55, u, h),
        _key('XF2', 0x56, u, h),
        _key('SPACE', 0x35, u * 7.0, h),
        _key('XF3', 0x57, u, h),
        _key('XF4', 0x58, u, h),
        _key('XF5', 0x59, u, h),
        _keyMulti(['全角'], 0x60, u * 1.5, h),
      ],
      mainSumU: 1.5 + 1 + 1 + 7 + 1 + 1 + 1 + 1.5,
      cursor: [
        _key('OPT.1', 0x72, u * 1.5, h),
        _key('OPT.2', 0x73, u * 1.5, h),
      ],
      cursorSumU: 3,
      numpad: [
        // 0 (1u), , (1u), . (1u), ENTER 領域 (1u, Stack で覆う)
        _key('0', 0x4F, u, h),
        _key(',', 0x50, u, h),
        _key('.', 0x51, u, h),
        SizedBox(width: u),
      ],
      numpadSumU: 4,
    );
  }

  // ---------------------------------------------------------------------------
  // Key widgets
  // ---------------------------------------------------------------------------

  Widget _key(String label, int scancode, double width, double height) {
    return _keyMulti([label], scancode, width, height);
  }

  Widget _keyMulti(List<String> labels, int scancode, double width, double height) {
    final pressed = _pressed.contains(scancode);
    final stuck = widget.stickyController.isStuck(scancode);
    final ledOn = widget.shared.isLedOn(scancode);
    final hasLed = X68kKeyboardSharedState.ledBitToScancode.contains(scancode);

    // 表示ラベル切替:
    //   かな ON + ひらがな ON  → ひらがな
    //   かな ON + ひらがな OFF → カタカナ
    //   かな OFF + SHIFT       → JIS 記号 (1-0 段、,./)
    //   かな OFF + 英字キー    → CAPS LED (0x5D) XOR SHIFT で大文字/小文字を切替
    //   それ以外               → 通常の英数記号
    final kanaActive = widget.shared.isLedOn(0x5A);
    final hiraganaActive = widget.shared.isLedOn(0x5F);
    final shiftPressed = _pressed.contains(0x70);
    String? overrideLabel;
    if (kanaActive) {
      overrideLabel = hiraganaActive
          ? _hiraganaLabels[scancode]
          : _katakanaLabels[scancode];
    } else if (shiftPressed) {
      overrideLabel = _shiftLabels[scancode];
    }
    // 英字キーは元ラベル ('A', 'Q' 等) が大文字なので、小文字状態のときだけ
    // 変換する。CAPS と SHIFT のどちらか片方だけ ON なら大文字、両方 OFF または
    // 両方 ON なら小文字 (典型的な CAPS LOCK の挙動と一致)。
    if (overrideLabel == null && !kanaActive && _letterScancodes.contains(scancode)) {
      final capsOn = widget.shared.isLedOn(0x5D);
      final isUpper = capsOn ^ shiftPressed;
      if (!isUpper) {
        overrideLabel = labels.first.toLowerCase();
      }
    }
    final displayLabels =
        overrideLabel != null ? <String>[overrideLabel] : labels;

    // LED 色分け (緑: ひらがな/全角, 赤: それ以外)
    final isGreen = _greenLedScancodes.contains(scancode);
    final ledColor = isGreen ? const Color(0xFF66FF88) : const Color(0xFFFF5555);
    final ledColorDim = isGreen ? const Color(0xFF1a3a1a) : const Color(0xFF3a1414);
    final ledGlow = isGreen ? const Color(0x8866FF88) : const Color(0x88FF5555);

    // ポップアップは Overlay で描画するため、各キーの BuildContext を Builder で確保
    return Builder(
      builder: (keyCtx) => SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: const EdgeInsets.all(1.5),
          child: GestureDetector(
            onTapDown: (d) => _handleKeyDown(scancode, d, keyCtx, displayLabels),
            onTapUp: (_) => _release(scancode),
            onTapCancel: () => _release(scancode),
            // 右クリック / 二次タップ: 任意キーを sticky toggle
            onSecondaryTap: () => _handleSecondaryTap(scancode),
            child: Stack(
              children: [
                Container(
                  decoration: BoxDecoration(
                    // sticky 中はオレンジで塗り、押下中 (sticky 含む) は明色背景にする。
                    color: pressed
                        ? const Color(0xFF505050)
                        : const Color(0xFF222222),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(
                      color: stuck
                          ? const Color(0xFFFFB300) // amber (sticky)
                          : pressed
                              ? Colors.white
                              : const Color(0xFF555555),
                      width: (stuck || pressed) ? 2 : 1,
                    ),
                  ),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: displayLabels
                          .map((s) => Text(
                                s,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color: pressed ? Colors.white : Colors.grey.shade300,
                                  fontSize: _autoFontSize(s, width, height),
                                  height: 1.0,
                                ),
                              ))
                          .toList(),
                    ),
                  ),
                ),
                if (hasLed)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Center(
                      child: Container(
                        // キー下端にぴったり付いた LED バー (実機の LED 表示風)
                        width: width * 0.5,
                        height: 6,
                        decoration: BoxDecoration(
                          color: ledOn
                              ? _applyBrightness(ledColor, widget.shared.ledBrightness)
                              : ledColorDim,
                          borderRadius: const BorderRadius.only(
                            topLeft: Radius.circular(1),
                            topRight: Radius.circular(1),
                          ),
                          boxShadow: ledOn
                              ? [
                                  BoxShadow(
                                    color: _applyBrightness(ledGlow, widget.shared.ledBrightness),
                                    blurRadius: 5,
                                    spreadRadius: 0.5,
                                  ),
                                ]
                              : null,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // 輝度レベル (0=最も明るい, 3=最も暗い) を RGB に乗算 (alpha は維持)
  Color _applyBrightness(Color base, int level) {
    final f = _brightnessFactors[level.clamp(0, _brightnessFactors.length - 1)];
    return base.withValues(
      red: (base.r * f).clamp(0.0, 1.0),
      green: (base.g * f).clamp(0.0, 1.0),
      blue: (base.b * f).clamp(0.0, 1.0),
    );
  }

  double _autoFontSize(String label, double w, double h) {
    final size = w < h ? w : h;
    if (label.length <= 1) return size * 0.45;
    if (label.length <= 3) return size * 0.32;
    if (label.length <= 5) return size * 0.22;
    return size * 0.18;
  }
}

// =============================================================================
// マウス トラックパッド + 左右ボタン
// =============================================================================
// プロトコル仕様 §4.3 準拠:
//   Note On/Off ch=mouse, note=0(L)/1(R)
//   CC ch=mouse, control=0x30(dX)/0x31(dY), value=64+delta (-64..+63)
// =============================================================================

class _TrackpadArea extends StatelessWidget {
  final MidiService midi;
  final int channel;
  const _TrackpadArea({required this.midi, required this.channel});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
      child: Row(
        children: [
          _MouseButton(
            midi: midi, channel: channel, note: 0,  // 左ボタン
            label: 'L',
          ),
          const SizedBox(width: 6),
          Expanded(child: _TrackpadSurface(midi: midi, channel: channel)),
          const SizedBox(width: 6),
          _MouseButton(
            midi: midi, channel: channel, note: 1,  // 右ボタン
            label: 'R',
          ),
        ],
      ),
    );
  }
}

class _MouseButton extends StatefulWidget {
  final MidiService midi;
  final int channel;
  final int note;
  final String label;
  const _MouseButton({
    required this.midi,
    required this.channel,
    required this.note,
    required this.label,
  });
  @override
  State<_MouseButton> createState() => _MouseButtonState();
}

class _MouseButtonState extends State<_MouseButton> {
  bool _pressed = false;

  void _down() {
    if (_pressed) return;
    setState(() => _pressed = true);
    widget.midi.sendNoteOn(widget.channel, widget.note, 127);
    HapticFeedback.lightImpact();
  }

  void _up() {
    if (!_pressed) return;
    setState(() => _pressed = false);
    widget.midi.sendNoteOff(widget.channel, widget.note);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _down(),
      onTapUp: (_) => _up(),
      onTapCancel: () => _up(),
      child: Container(
        width: 56,
        decoration: BoxDecoration(
          color: _pressed ? const Color(0xFF505050) : const Color(0xFF222222),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: _pressed ? Colors.white : const Color(0xFF555555),
            width: _pressed ? 2 : 1,
          ),
        ),
        child: Center(
          child: Text(
            widget.label,
            style: TextStyle(
              color: _pressed ? Colors.white : Colors.grey.shade300,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}

class _TrackpadSurface extends StatefulWidget {
  final MidiService midi;
  final int channel;
  const _TrackpadSurface({required this.midi, required this.channel});
  @override
  State<_TrackpadSurface> createState() => _TrackpadSurfaceState();
}

class _TrackpadSurfaceState extends State<_TrackpadSurface> {
  static const int _ccDx = 0x30;
  static const int _ccDy = 0x31;
  static const int _noteLeft = 0;
  // 1 ピクセル = 何マウスカウントか。実機の感度に合わせて軽く調整可
  static const double _sensitivity = 1.0;
  static const Duration _flushPeriod = Duration(milliseconds: 16);

  double _accumDx = 0;
  double _accumDy = 0;
  Timer? _flushTimer;

  // 各 pan 開始時の指の位置を覚えておき、ここからの相対量を取る
  // (DragUpdateDetails.delta が pan 境界をまたぐ際に変な値になるケース対策)
  Offset? _lastPos;

  @override
  void initState() {
    super.initState();
    _flushTimer = Timer.periodic(_flushPeriod, (_) => _flush());
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }

  void _flush() {
    var dx = _accumDx.round();
    var dy = _accumDy.round();
    if (dx == 0 && dy == 0) return;
    _accumDx -= dx;
    _accumDy -= dy;

    // CC は 7 bit (-64..+63) なので、超える分は連続送信して累積させる (§4.3.3)
    while (dx != 0) {
      final chunk = dx.clamp(-63, 63);
      widget.midi.sendCC(widget.channel, _ccDx, 64 + chunk);
      dx -= chunk;
    }
    while (dy != 0) {
      final chunk = dy.clamp(-63, 63);
      widget.midi.sendCC(widget.channel, _ccDy, 64 + chunk);
      dy -= chunk;
    }
  }

  void _onPanStart(DragStartDetails d) {
    _lastPos = d.localPosition;
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final last = _lastPos;
    if (last == null) {
      // onPanStart を経由しない場合の保険
      _lastPos = d.localPosition;
      return;
    }
    final dx = d.localPosition.dx - last.dx;
    final dy = d.localPosition.dy - last.dy;
    _lastPos = d.localPosition;
    _accumDx += dx * _sensitivity;
    _accumDy += dy * _sensitivity;
  }

  void _onPanEnd(DragEndDetails d) {
    _lastPos = null;
  }

  void _onPanCancel() {
    _lastPos = null;
  }

  // タップ = 左クリック (Note On → 短い遅延 → Note Off)
  void _onTap() {
    HapticFeedback.lightImpact();
    widget.midi.sendNoteOn(widget.channel, _noteLeft, 127);
    Future.delayed(const Duration(milliseconds: 40), () {
      widget.midi.sendNoteOff(widget.channel, _noteLeft);
    });
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: _onPanStart,
      onPanUpdate: _onPanUpdate,
      onPanEnd: _onPanEnd,
      onPanCancel: _onPanCancel,
      onTap: _onTap,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1a1f24),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF555555)),
        ),
        child: const Center(
          child: Text(
            'TRACKPAD',
            style: TextStyle(
              color: Color(0xFF444444),
              fontSize: 14,
              letterSpacing: 4,
            ),
          ),
        ),
      ),
    );
  }
}

// ===========================================================================
// LineInputMode — 1 行のテキストフィールドにまとめて入力し、Enter / 送信
// ボタンで文字列を X68000 にタイプする入力モード。
//
// 文字 → スキャンコード変換は JIS 配列基準。大文字 (A-Z) や JIS の Shift 記号
// (! " # 等) は SHIFT 修飾を自動付与する。
// 送信前に LED トグル系 (かな/CAPS/ローマ字/コード入力/ひらがな/全角/INS) を
// 観測中の状態に基づいてオフに戻し、押下中の可能性がある修飾キーを強制 release
// する。これでクリーンな状態から打ち始める。
// 漢字等の未対応文字は現バージョンではスキップ (送信完了時に件数を表示)。
// ===========================================================================

class LineInputMode extends ChannelMode {
  final int channel;
  final X68kKeyboardSharedState shared;
  final TextEditingController _controller = TextEditingController();
  // 送信履歴。モードを切り替えても消えないように body 側でなく mode 側に持つ。
  // SharedPreferences で永続化 (アプリ再起動でも残る)。
  final List<String> _history = [];
  static const int _maxHistory = 100;
  static const String _prefsKey = 'lineInput.history';

  LineInputMode({required this.channel, required this.shared}) {
    // 起動時に SharedPreferences から履歴を非同期で読み込む。
    // 読み込み完了後に notifyListeners() を呼んで body の再描画を促す。
    _loadHistory();
  }

  /// 履歴の不変ビュー (body 側からの読み取り用)。
  List<String> get history => List<String>.unmodifiable(_history);

  Future<void> _loadHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getStringList(_prefsKey);
      if (saved != null && saved.isNotEmpty) {
        _history
          ..clear()
          ..addAll(saved.take(_maxHistory));
        notifyListeners();
      }
    } catch (_) {
      // 読み込み失敗時は空のままで続行
    }
  }

  Future<void> _saveHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, _history);
    } catch (_) {
      // 保存失敗は無視 (致命的でない)
    }
  }

  /// 履歴に追加する。重複は先頭に移動し、上限を超えた末尾を切り捨てる。
  void addToHistory(String text) {
    if (text.isEmpty) return;
    _history.remove(text);
    _history.insert(0, text);
    if (_history.length > _maxHistory) {
      _history.removeRange(_maxHistory, _history.length);
    }
    notifyListeners();
    _saveHistory();
  }

  /// 履歴から 1 件削除する。
  void removeFromHistory(String text) {
    if (_history.remove(text)) {
      notifyListeners();
      _saveHistory();
    }
  }

  @override
  String get id => 'x68k_keyboard.lineInput';

  @override
  String label(BuildContext context) => 'ライン入力';

  @override
  void onActiveChanged(bool active, MidiService midi) {
    if (active) {
      // ライン入力は portrait / landscape どちらでも使えるよう向きの固定を解除。
      OrientationHelper.unlock();
      // 漢字入力のため Windows IME を有効化する (他モード/他画面では無効)。
      WindowsIme.setEnabled(true);
    } else {
      // 背面化したら IME を無効に戻す (前面の画面がキー入力を奪われないよう)。
      WindowsIme.setEnabled(false);
    }
  }

  @override
  Future<void> onExit(MidiService midi) async {
    // 他モードへ切り替えるとき IME を無効に戻す (背面化は onActiveChanged で処理)。
    await WindowsIme.setEnabled(false);
  }

  @override
  Widget buildBody(BuildContext context, MidiService midi) {
    return _LineInputBody(
      midi: midi,
      channel: channel,
      controller: _controller,
      shared: shared,
      mode: this,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }
}

class _LineInputBody extends StatefulWidget {
  final MidiService midi;
  final int channel;
  final TextEditingController controller;
  final X68kKeyboardSharedState shared;
  final LineInputMode mode;

  const _LineInputBody({
    required this.midi,
    required this.channel,
    required this.controller,
    required this.shared,
    required this.mode,
  });

  @override
  State<_LineInputBody> createState() => _LineInputBodyState();
}

class _LineInputBodyState extends State<_LineInputBody> {
  final FocusNode _focusNode = FocusNode();
  bool _sending = false;
  String _status = '';

  @override
  void initState() {
    super.initState();
    // mode の notifyListeners (履歴 load / add / remove) で再描画する。
    widget.mode.addListener(_onModeChanged);
  }

  void _onModeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.mode.removeListener(_onModeChanged);
    _focusNode.dispose();
    super.dispose();
  }

  // 機能キー (BS / DEL / TAB / ESC / INS / HOME / CLR / カーソル) の定義。
  // 各ボタンは押下で 1 回だけ NoteOn/Off ペアを送る。
  static const List<({String label, int scancode})> _functionKeys = [
    (label: 'ESC', scancode: 0x01),
    (label: 'TAB', scancode: 0x10),
    (label: 'BS', scancode: 0x0F),
    (label: 'DEL', scancode: 0x37),
    (label: 'INS', scancode: 0x5E),
    (label: 'HOME', scancode: 0x36),
    (label: 'CLR', scancode: 0x3F),
    (label: '←', scancode: 0x3B),
    (label: '↓', scancode: 0x3E),
    (label: '↑', scancode: 0x3C),
    (label: '→', scancode: 0x3D),
  ];

  // a-z (logical) を X68k スキャンコード A-Z の順で並べたもの。
  static const List<int> _letterScancodes = [
    0x1E, 0x2E, 0x2C, 0x20, 0x13, 0x21, 0x22, 0x23, // A B C D E F G H
    0x18, 0x24, 0x25, 0x26, 0x30, 0x2F, 0x19, 0x1A, // I J K L M N O P
    0x11, 0x14, 0x1F, 0x15, 0x17, 0x2D, 0x12, 0x2B, // Q R S T U V W X
    0x16, 0x2A, //                                    Y Z
  ];
  // 0-9 → 各スキャンコード
  static const List<int> _digitScancodes = [
    0x0B, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A,
  ];
  // それ以外の記号類。値は (scancode, 要 SHIFT) の record。
  static const Map<String, (int, bool)> _symbolMap = {
    // SHIFT 不要 (JIS 素押し)
    ' ': (0x35, false),
    '-': (0x0C, false),
    '^': (0x0D, false),
    '¥': (0x0E, false),
    '\\': (0x0E, false), // US の \ も JIS の ¥ に割り当て
    '@': (0x1B, false),
    '[': (0x1C, false),
    ';': (0x27, false),
    ':': (0x28, false),
    ']': (0x29, false),
    ',': (0x31, false),
    '.': (0x32, false),
    '/': (0x33, false),
    // SHIFT + その他キーで出る JIS 記号
    '!': (0x02, true),
    '"': (0x03, true),
    '#': (0x04, true),
    '\$': (0x05, true),
    '%': (0x06, true),
    '&': (0x07, true),
    "'": (0x08, true),
    '(': (0x09, true),
    ')': (0x0A, true),
    '=': (0x0C, true),
    '~': (0x0D, true),
    '|': (0x0E, true),
    '`': (0x1B, true),
    '{': (0x1C, true),
    '+': (0x27, true),
    '*': (0x28, true),
    '}': (0x29, true),
    '<': (0x31, true),
    '>': (0x32, true),
    '?': (0x33, true),
    '_': (0x34, true),
    // 制御文字
    '\n': (0x1D, false), // 改行 → RETURN
    '\t': (0x10, false), // タブ
  };

  /// 1 文字 → (scancode, SHIFT 要否)。マップ外なら null。
  static (int, bool)? _charToScancode(String char) {
    if (char.length != 1) return null;
    final code = char.codeUnitAt(0);
    // a-z
    if (code >= 0x61 && code <= 0x7A) {
      return (_letterScancodes[code - 0x61], false);
    }
    // A-Z
    if (code >= 0x41 && code <= 0x5A) {
      return (_letterScancodes[code - 0x41], true);
    }
    // 0-9
    if (code >= 0x30 && code <= 0x39) {
      return (_digitScancodes[code - 0x30], false);
    }
    return _symbolMap[char];
  }

  // X68k スキャンコード定数
  static const int _scShift = 0x70;
  static const int _scCodeInput = 0x5C;
  // 送信前に強制 release する修飾キー (SHIFT/CTRL/OPT.1/OPT.2/XF1-5)
  static const List<int> _modifiersToRelease = [
    0x70, 0x71, 0x72, 0x73, 0x55, 0x56, 0x57, 0x58, 0x59,
  ];
  // 観測した LED のうち点灯中ならトグル押下でオフに戻す対象スキャンコード
  static const List<int> _toggleKeysToClear = [
    0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60,
  ];

  // タイミング
  static const Duration _intraKeyDelay = Duration(milliseconds: 15);
  static const Duration _interKeyDelay = Duration(milliseconds: 25);

  Future<void> _send() async {
    if (_sending) return;
    final text = widget.controller.text;
    if (text.isEmpty) {
      // 空行 + Enter は X68000 に RETURN (改行) を 1 回送る。
      // 履歴には追加しない (空文字を履歴に残しても意味がないため)。
      setState(() {
        _sending = true;
        _status = '改行送信中...';
      });
      debugPrint('[LineInput] === send empty (RETURN only) ===');
      try {
        await _resetState();
        await _sendOneChar(0x1D, false); // X68k RETURN
        if (mounted) setState(() => _status = '改行を送信');
      } catch (e) {
        if (mounted) setState(() => _status = 'エラー: $e');
      } finally {
        if (mounted) setState(() => _sending = false);
        _restoreFocusAfterFrame();
      }
      return;
    }
    final runes = text.runes.toList();
    setState(() {
      _sending = true;
      _status = '送信中... 0/${runes.length}';
    });
    int sent = 0;
    int skipped = 0;
    // コード入力モードの状態を追跡 (toggle なので前回の状態を覚えておく)。
    // _resetState が toggle 系をすべてオフにするので false スタートで OK。
    bool inCodeMode = false;

    Future<void> ensureCodeMode(bool desired) async {
      if (inCodeMode == desired) return;
      debugPrint(
          '[LineInput] toggle code-input mode ${desired ? 'ON' : 'OFF'}');
      await _sendOneChar(_scCodeInput, false);
      inCodeMode = desired;
      await Future.delayed(_interKeyDelay);
    }

    debugPrint('[LineInput] === send start: "$text" (${runes.length} codepoints) ===');
    try {
      await _resetState();
      for (int i = 0; i < runes.length; i++) {
        final cp = runes[i];
        final raw = String.fromCharCode(cp);
        final asciiMapping = _charToScancode(raw);
        if (asciiMapping != null) {
          // ASCII 系: コード入力モードを抜けてから直接送る
          await ensureCodeMode(false);
          debugPrint('[LineInput]   send[$i] "$raw"'
              ' → scancode=0x${asciiMapping.$1.toRadixString(16).padLeft(2, '0')}'
              ' shift=${asciiMapping.$2}');
          await _sendOneChar(asciiMapping.$1, asciiMapping.$2);
          sent++;
        } else {
          // SJIS にエンコードしてコード入力モードで送る
          final sjis = SjisEncoder.encode(cp);
          if (sjis != null) {
            await ensureCodeMode(true);
            debugPrint('[LineInput]   send[$i] "$raw"'
                ' U+${cp.toRadixString(16).padLeft(4, '0').toUpperCase()}'
                ' → SJIS=0x${sjis.toRadixString(16).padLeft(4, '0').toUpperCase()}');
            await _sendSjisHex(sjis);
            sent++;
          } else {
            debugPrint('[LineInput]   skip[$i] "$raw"'
                ' U+${cp.toRadixString(16).padLeft(4, '0').toUpperCase()}'
                ' (SJIS にマップなし)');
            skipped++;
          }
        }
        if ((i & 0x07) == 0 && mounted) {
          setState(() {
            _status = '送信中... ${i + 1}/${runes.length}';
          });
        }
        await Future.delayed(_interKeyDelay);
      }
      // 最後にコード入力モードを抜けておく
      await ensureCodeMode(false);
      debugPrint('[LineInput] === send done: sent=$sent skipped=$skipped ===');
      if (mounted) {
        // 履歴に追加 (重複は先頭に移動 + 永続化) し、入力欄をクリア。
        widget.mode.addToHistory(text);
        widget.controller.clear();
        setState(() {
          _status = '完了 (送信 $sent 文字, スキップ $skipped 文字)';
        });
      }
    } catch (e) {
      debugPrint('[LineInput] !! error during send: $e');
      if (mounted) {
        setState(() => _status = 'エラー: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _sending = false);
      }
      _restoreFocusAfterFrame();
    }
  }

  /// TextField.onSubmitted は内部で focus を外す挙動があるため、次フレーム以降に
  /// 改めて requestFocus する。同期的に呼ぶと、TextField 側の unfocus に上書き
  /// されてしまう。
  void _restoreFocusAfterFrame() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  /// SJIS のコードを 4 桁 hex (16-bit 値 MSB から) として X68000 のキー入力で送る。
  /// コード入力モードに入っている前提。
  Future<void> _sendSjisHex(int sjisCode) async {
    for (int shift = 12; shift >= 0; shift -= 4) {
      final hex = (sjisCode >> shift) & 0x0F;
      final scancode = _hexDigitToScancode(hex);
      debugPrint('[LineInput]     hex ${hex.toRadixString(16).toUpperCase()}'
          ' → scancode=0x${scancode.toRadixString(16)}');
      await _sendOneChar(scancode, false);
      await Future.delayed(_intraKeyDelay);
    }
  }

  /// 0..F の hex 数字に対応する X68k スキャンコードを返す
  /// (0-9 は数字行、A-F は A-F キー、いずれも SHIFT 不要)。
  static int _hexDigitToScancode(int hex) {
    if (hex < 10) return _digitScancodes[hex];
    return _letterScancodes[hex - 10]; // A..F → letterScancodes[0..5]
  }

  /// 送信前に X68000 のキーボード状態をクリーンに戻す。
  Future<void> _resetState() async {
    debugPrint('[LineInput] reset: release modifiers');
    // 押下中の可能性がある修飾キーを強制 release (no-op の場合も含めて安全)。
    for (final code in _modifiersToRelease) {
      widget.midi.sendNoteOff(widget.channel, code);
    }
    await Future.delayed(_intraKeyDelay);

    // 観測中の LED が点灯している toggle key を押してオフに戻す。
    final leds = widget.shared.ledOn;
    debugPrint('[LineInput] reset: ledOn snapshot = '
        '${leds.map((c) => '0x${c.toRadixString(16)}').join(',')}');
    for (final code in _toggleKeysToClear) {
      if (leds.contains(code)) {
        debugPrint('[LineInput] reset: toggle off 0x${code.toRadixString(16)}');
        widget.midi.sendNoteOn(widget.channel, code, 127);
        await Future.delayed(_intraKeyDelay);
        widget.midi.sendNoteOff(widget.channel, code);
        await Future.delayed(_interKeyDelay);
      }
    }
  }

  Future<void> _sendOneChar(int scancode, bool needShift) async {
    final ch = widget.channel;
    if (needShift) {
      widget.midi.sendNoteOn(ch, _scShift, 127);
      await Future.delayed(_intraKeyDelay);
    }
    widget.midi.sendNoteOn(ch, scancode, 127);
    await Future.delayed(_intraKeyDelay);
    widget.midi.sendNoteOff(ch, scancode);
    if (needShift) {
      await Future.delayed(_intraKeyDelay);
      widget.midi.sendNoteOff(ch, _scShift);
    }
  }

  void _clear() {
    widget.controller.clear();
    setState(() => _status = '');
    _focusNode.requestFocus();
  }

  /// 履歴の 1 件を入力欄にロード (送信はしない)。
  void _loadFromHistory(String text) {
    widget.controller.text = text;
    widget.controller.selection =
        TextSelection.collapsed(offset: text.length);
    _focusNode.requestFocus();
  }

  /// 履歴の 1 件を削除する (永続化も連動)。
  void _removeFromHistory(String text) {
    widget.mode.removeFromHistory(text);
    _focusNode.requestFocus();
  }

  /// 機能キー (BS / DEL / TAB / ESC / INS / カーソル等) を 1 回押下する。
  /// 履歴やテキストフィールドには影響せず、X68000 へ即座に送る。
  Future<void> _pressFunctionKey(int scancode) async {
    debugPrint('[LineInput] function key: scancode=0x'
        '${scancode.toRadixString(16).padLeft(2, '0')}');
    widget.midi.sendNoteOn(widget.channel, scancode, 127);
    await Future.delayed(_intraKeyDelay);
    widget.midi.sendNoteOff(widget.channel, scancode);
    _focusNode.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final hintColor = colors.onSurface.withValues(alpha: 0.35);
    // 全体を SingleChildScrollView で包み、ソフトウェアキーボード表示時や狭い
    // landscape phone でも領域不足にならないようにする。履歴も list ではなく
    // 通常 Column で全件描画して、outer scroll に任せる。
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 入力行
            TextField(
              controller: widget.controller,
              focusNode: _focusNode,
              autofocus: true,
              enabled: !_sending,
              decoration: InputDecoration(
                hintText: 'X68000 に送る文字列 (Enter で送信、空 Enter で改行)',
                hintStyle: TextStyle(color: hintColor),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onSubmitted: (_) => _send(),
            ),
            const SizedBox(height: 8),
            // 送信 / クリア + ステータス
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  onPressed: _sending ? null : _send,
                  icon: const Icon(Icons.send, size: 18),
                  label: const Text('送信'),
                ),
                OutlinedButton.icon(
                  onPressed: _sending ? null : _clear,
                  icon: const Icon(Icons.clear, size: 18),
                  label: const Text('クリア'),
                ),
                if (_status.isNotEmpty)
                  Text(
                    _status,
                    style: const TextStyle(color: Colors.grey, fontSize: 12),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // 機能キー (BS / DEL / TAB / ESC / INS / HOME / CLR / カーソル)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final fk in _functionKeys)
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      minimumSize: const Size(40, 32),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: _sending
                        ? null
                        : () => _pressFunctionKey(fk.scancode),
                    child: Text(fk.label,
                        style: const TextStyle(fontSize: 12)),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // 履歴一覧 (タップでロード、送信はしない)
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: colors.outlineVariant),
                borderRadius: BorderRadius.circular(4),
              ),
              child: widget.mode.history.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 20),
                      child: Center(
                        child: Text(
                          '送信履歴はここに表示されます (タップで入力欄にロード)',
                          style: TextStyle(color: hintColor, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : Column(
                      children: [
                        for (final item in widget.mode.history)
                          InkWell(
                            onTap: () => _loadFromHistory(item),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              child: Row(
                                children: [
                                  Icon(Icons.history,
                                      size: 14, color: hintColor),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      item,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                  // ×: 行高を変えないようコンパクトなボタンに
                                  IconButton(
                                    icon: Icon(Icons.close,
                                        size: 14, color: hintColor),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                      minWidth: 22,
                                      minHeight: 22,
                                    ),
                                    splashRadius: 12,
                                    visualDensity: VisualDensity.compact,
                                    tooltip: '履歴から削除',
                                    onPressed: () =>
                                        _removeFromHistory(item),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// ===========================================================================
// TV リモコンモード
// SHARP G0737SA "ディスプレイテレビ" 純正リモコンの配置を模した専用 UI。
// 各ボタンは押下時に midi.emitRemote(code) を 1 回送出し、
// DisplayControlCommand.remoteRepeatInterval が設定されているもの
// (ボリュームアップ/ダウン等) は押下中その間隔で連続発射する。
// channel は不要 (emitRemote は SysEx なので MIDI チャンネルに依存しない)。
// ===========================================================================

class TvRemoteMode extends ChannelMode {
  @override
  String get id => 'x68k_keyboard.tvRemote';

  @override
  String label(BuildContext context) => 'TVリモコン';

  @override
  void onActiveChanged(bool active, MidiService midi) {
    // リモコンは portrait が自然だが、landscape でも使えるよう向き固定は解除。
    // 前面のときだけ適用 (背面のときは相手画面の向きを尊重)。
    if (active) OrientationHelper.unlock();
  }

  @override
  Widget buildBody(BuildContext context, MidiService midi) {
    return _TvRemoteBody(midi: midi);
  }
}

class _TvRemoteBody extends StatefulWidget {
  final MidiService midi;
  const _TvRemoteBody({required this.midi});

  @override
  State<_TvRemoteBody> createState() => _TvRemoteBodyState();
}

class _TvRemoteBodyState extends State<_TvRemoteBody> {
  // 押下中の REMOTE 連続発射用 Timer (volUp/volDown 等)。
  // _pressedCode を見て自己キャンセルする。別キーが押されたら上書きする。
  Timer? _repeatTimer;
  int? _pressedCode;

  @override
  void dispose() {
    _repeatTimer?.cancel();
    super.dispose();
  }

  void _onPress(DisplayControlCommand cmd) {
    widget.midi.emitRemote(cmd.code);
    HapticFeedback.lightImpact();
    _repeatTimer?.cancel();
    _repeatTimer = null;
    _pressedCode = cmd.code;
    final interval = cmd.remoteRepeatInterval;
    if (interval == null) return;
    _repeatTimer = Timer.periodic(interval, (_) {
      if (_pressedCode != cmd.code) {
        _repeatTimer?.cancel();
        _repeatTimer = null;
        return;
      }
      widget.midi.emitRemote(cmd.code);
    });
  }

  void _onRelease(DisplayControlCommand cmd) {
    if (_pressedCode == cmd.code) {
      _pressedCode = null;
      _repeatTimer?.cancel();
      _repeatTimer = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF1a1a1a),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            // 4 列 × 6 行のグリッド。固定アスペクト比は持たず、画面の縦横に
            // 合わせてセルが伸び縮みする (横長画面では横長セルになる)。
            // 極端な縦長/横長を避けるため cellW/cellH を [0.6, 3.0] に制限。
            // ラベル本体は FittedBox(scaleDown) で必ず収まるよう縮小される。
            const cols = 4;
            const rows = 6;
            const minWHRatio = 0.6;
            const maxWHRatio = 3.0;
            const outerPadH = 12.0;
            const outerPadV = 12.0;
            const borderW = 1.0;
            final availW =
                constraints.maxWidth - (outerPadH + borderW) * 2;
            final availH =
                constraints.maxHeight - (outerPadV + borderW) * 2;
            double cellW = availW / cols;
            double cellH = availH / rows;
            if (cellW < cellH * minWHRatio) cellH = cellW / minWHRatio;
            if (cellW > cellH * maxWHRatio) cellW = cellH * maxWHRatio;
            return Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: outerPadH, vertical: outerPadV),
                decoration: BoxDecoration(
                  color: const Color(0xFF2a2a2a),
                  borderRadius: BorderRadius.circular(14),
                  border:
                      Border.all(color: Colors.grey.shade800, width: borderW),
                ),
                child: _buildGrid(cellW, cellH),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildGrid(double cw, double ch) {
    // 各セルは _TvRemoteButton (ラベルはボタン本体の表面に描画)。
    // ボタンを置かないセルは SizedBox(cw, ch) でスペースだけ確保する。
    // [subLabel] を指定すると上下 2 行 + 区切り横棒で描画 (トグルボタン表現)。
    Widget btn(
      DisplayControlCommand cmd,
      String label, {
      String? subLabel,
      double fontSize = 13,
    }) =>
        _TvRemoteButton(
          label: label,
          subLabel: subLabel,
          fontSize: fontSize,
          width: cw,
          height: ch,
          onPress: () => _onPress(cmd),
          onRelease: () => _onRelease(cmd),
        );
    final gap = SizedBox(width: cw, height: ch);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Row 0: テレビ/ビデオ/コンピュータ (左端) ... 電源 (右端)
        Row(mainAxisSize: MainAxisSize.min, children: [
          btn(DisplayControlCommand.tvCom, 'テレビ・ビデオ',
              subLabel: 'コンピュータ', fontSize: 9),
          gap,
          gap,
          btn(DisplayControlCommand.powerToggle, '電源', fontSize: 14),
        ]),
        // Row 1: (左列 空), 音量小, 音量大, 消音
        Row(mainAxisSize: MainAxisSize.min, children: [
          gap,
          btn(DisplayControlCommand.volDown, '音量\n小', fontSize: 12),
          btn(DisplayControlCommand.volUp, '音量\n大', fontSize: 12),
          btn(DisplayControlCommand.mute, '消音', fontSize: 13),
        ]),
        // Row 2: 副音声, 1, 2, 3
        Row(mainAxisSize: MainAxisSize.min, children: [
          btn(DisplayControlCommand.subAudio, '主音声',
              subLabel: '副音声', fontSize: 11),
          btn(DisplayControlCommand.ch1, '1', fontSize: 22),
          btn(DisplayControlCommand.ch2, '2', fontSize: 22),
          btn(DisplayControlCommand.ch3, '3', fontSize: 22),
        ]),
        // Row 3: (左列 空), 4, 5, 6
        Row(mainAxisSize: MainAxisSize.min, children: [
          gap,
          btn(DisplayControlCommand.ch4, '4', fontSize: 22),
          btn(DisplayControlCommand.ch5, '5', fontSize: 22),
          btn(DisplayControlCommand.ch6, '6', fontSize: 22),
        ]),
        // Row 4: テレビ/ビデオ, 7, 8, 9
        Row(mainAxisSize: MainAxisSize.min, children: [
          btn(DisplayControlCommand.video, 'テレビ',
              subLabel: 'ビデオ', fontSize: 11),
          btn(DisplayControlCommand.ch7, '7', fontSize: 22),
          btn(DisplayControlCommand.ch8, '8', fontSize: 22),
          btn(DisplayControlCommand.ch9, '9', fontSize: 22),
        ]),
        // Row 5: ch コール, 10, 11, 12
        Row(mainAxisSize: MainAxisSize.min, children: [
          btn(DisplayControlCommand.chCall, 'ch\nコール', fontSize: 12),
          btn(DisplayControlCommand.ch10, '10', fontSize: 18),
          btn(DisplayControlCommand.ch11, '11', fontSize: 18),
          btn(DisplayControlCommand.ch12, '12', fontSize: 18),
        ]),
      ],
    );
  }
}

/// TV リモコンの 1 ボタン。ボタン本体の中央にラベルを描画する。
/// [subLabel] が指定された場合は label/subLabel を上下 2 行で表示し、間に
/// 横棒の区切りを入れる (トグルボタンであることの視覚表現)。
/// 連続発射対応のため [Listener] の pointer イベントで press/release を判定する。
class _TvRemoteButton extends StatefulWidget {
  final String label;
  final String? subLabel;
  final double fontSize;
  final double width;
  final double height;
  final VoidCallback onPress;
  final VoidCallback onRelease;

  const _TvRemoteButton({
    required this.label,
    this.subLabel,
    required this.fontSize,
    required this.width,
    required this.height,
    required this.onPress,
    required this.onRelease,
  });

  @override
  State<_TvRemoteButton> createState() => _TvRemoteButtonState();
}

class _TvRemoteButtonState extends State<_TvRemoteButton> {
  bool _pressed = false;

  void _setPressed(bool v) {
    if (_pressed == v) return;
    setState(() => _pressed = v);
  }

  TextStyle get _labelStyle => TextStyle(
        color: Colors.white.withValues(alpha: 0.95),
        fontSize: widget.fontSize,
        height: 1.1,
        fontWeight: FontWeight.w500,
      );

  Widget _buildSingleLabel() => Text(
        widget.label,
        textAlign: TextAlign.center,
        style: _labelStyle,
        softWrap: false,
        overflow: TextOverflow.visible,
      );

  /// label / 横棒区切り / subLabel の縦 3 段。トグル感を出す。
  /// 横棒の長さは長い方のラベルの描画幅 × 1.1。
  Widget _buildSplitLabel() {
    double measure(String text) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: _labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      return tp.width;
    }

    final w1 = measure(widget.label);
    final w2 = measure(widget.subLabel!);
    final lineWidth = (w1 > w2 ? w1 : w2) * 1.1;

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.label,
            textAlign: TextAlign.center,
            style: _labelStyle,
            softWrap: false,
            overflow: TextOverflow.visible),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: SizedBox(
            width: lineWidth,
            height: 1,
            child: ColoredBox(color: Colors.grey.shade500),
          ),
        ),
        Text(widget.subLabel!,
            textAlign: TextAlign.center,
            style: _labelStyle,
            softWrap: false,
            overflow: TextOverflow.visible),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Padding(
        padding: const EdgeInsets.all(3),
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (_) {
            _setPressed(true);
            widget.onPress();
          },
          onPointerUp: (_) {
            _setPressed(false);
            widget.onRelease();
          },
          onPointerCancel: (_) {
            _setPressed(false);
            widget.onRelease();
          },
          child: Container(
            decoration: BoxDecoration(
              color: _pressed
                  ? const Color(0xFF555555)
                  : const Color(0xFF1c1c1c),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: Colors.grey.shade700, width: 0.6),
            ),
            padding: const EdgeInsets.all(3),
            // FittedBox がセル内に必ず収まるよう自動的にラベルを縮小する。
            // softWrap:false 付きの Text と組み合わせて「文字を折り返さず
            // フォントサイズを下げる」挙動を実現する。
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.center,
              child: widget.subLabel == null
                  ? _buildSingleLabel()
                  : _buildSplitLabel(),
            ),
          ),
        ),
      ),
    );
  }
}
