// 標準キーボード画面の IME 入力バー。
//
// 日本語 IM がオンになったら (ImeState.japaneseOn) キーボードの上に 1 行の
// 入力欄を出してフォーカスを移し、変換を確定した文字列を X68kTextTyper で
// X68000 にタイプする (漢字はコード入力)。IM をオフ (英数) に戻すと入力欄を
// 消して、従来どおり物理キーをスキャンコードで直接送る経路に戻る。
//
// 物理キー側 (_X68kKeyboardBody._handlePhysicalKey) は、バー表示中は文字キーを
// IM に渡し、入力欄が空で変換中でもないときだけ Enter / BS / 矢印などを
// X68000 に直接送る。その判定に [ImeLineController.bufferEmpty] を使う。

import 'dart:async';

import 'package:flutter/material.dart';

import 'ime_state.dart';
import 'x68k_text_typer.dart';

class ImeLineController extends ChangeNotifier {
  ImeLineController() {
    ImeState.ensureStarted();
    ImeState.japaneseOn.addListener(_onImeChanged);
    text.addListener(_onTextChanged);
  }

  final TextEditingController text = TextEditingController();
  final FocusNode focusNode = FocusNode(debugLabel: 'ImeLineBar');

  /// 送信に使う typer。midi が分かった時点 (buildBody) で設定される。
  X68kTextTyper? typer;

  bool _active = false;

  /// キーボード画面が前面のときだけバーを出す (Combined で背面のときや、
  /// ライン入力モードに切り替えたときは出さない)。
  void setActive(bool active) {
    if (_active == active) return;
    _active = active;
    notifyListeners();
  }

  bool get visible => _active && ImeState.japaneseOn.value;

  bool get composing {
    final c = text.value.composing;
    return c.isValid && !c.isCollapsed;
  }

  /// 変換中でなく、確定済みの文字もすべて送信に回した
  /// (= 物理キーを X68000 に直接送ってよい)。
  bool get bufferEmpty => !composing && _sentLen >= text.text.length;

  /// 送信中または送信待ちがある。
  bool get busy => _running || _queue.isNotEmpty;

  /// 送信待ち。String = 確定文字列、int = 単発のキー (スキャンコード)、
  /// _CtrlKey = CTRL + キー。
  final List<Object> _queue = [];

  /// テスト用: 送信待ちの確定文字列 (typer 未設定なら送られずに残る)。
  @visibleForTesting
  List<String> get pendingTexts => _queue.whereType<String>().toList();
  bool _running = false;

  /// バーに出す直近の状態。送信中は「送信中: 〜」、送信が終わったら
  /// [_statusHoldOk] (送れない文字があったときは [_statusHoldSkipped]) で消す。
  String status = '';
  Timer? _statusClearTimer;
  static const Duration _statusHoldOk = Duration(seconds: 2);
  static const Duration _statusHoldSkipped = Duration(seconds: 6);

  void _setStatus(String value, {Duration? clearAfter}) {
    _statusClearTimer?.cancel();
    status = value;
    if (clearAfter != null) {
      _statusClearTimer = Timer(clearAfter, () {
        status = '';
        notifyListeners();
      });
    }
    notifyListeners();
  }

  void _onImeChanged() => notifyListeners();

  // --- 確定文字列の検出 ---
  //
  // 入力欄のうち変換中 (composing) より前の部分が確定済み。そのうち送信に
  // 回していない分 (_sentLen 以降) だけを送る。
  //
  // 確定のたびに入力欄を空にすると、IME が「前を確定して、続けて次の変換を
  // 始める」(例: 「ありがとう」変換中に「。」を押す) ときに、IME 側から
  // 空にする前の内容 (「ありがとう。」) で更新が届き、確定済みの部分を
  // もう一度送ってしまう。そのため入力欄はすぐには空にせず、全部送り終えて
  // しばらく操作が無いときに空にする。空にした直後に古い内容が届いた場合も、
  // その分は送信済みとして扱う。

  /// C0 制御文字と DEL。
  static final RegExp _controlChars = RegExp('[\x00-\x1F\x7F]');

  /// 入力欄の先頭から何文字 (UTF-16) を送信に回したか。
  int _sentLen = 0;

  /// 最後に入力欄を空にしたときの内容と時刻 (古い内容の更新を見分ける)。
  String? _clearedText;
  DateTime? _clearedAt;
  static const Duration _staleWindow = Duration(milliseconds: 500);

  Timer? _clearTimer;
  static const Duration _clearDelay = Duration(milliseconds: 800);

  /// 自分で入力欄を書き換えている最中 (listener を無視する)。
  bool _clearing = false;

  void _onTextChanged() {
    if (_clearing) return;
    _clearTimer?.cancel();
    final v = text.value;

    // 空にした直後に、空にする前の内容から続く更新が届いた。
    final cleared = _clearedText;
    if (cleared != null) {
      final recent = _clearedAt != null &&
          DateTime.now().difference(_clearedAt!) < _staleWindow;
      _clearedText = null;
      if (recent && v.text.startsWith(cleared)) {
        debugPrint('[ImeLine] stale update after clear: "${v.text}"');
        _sentLen = cleared.length;
      }
    }

    final c = v.composing;
    final committedEnd =
        (c.isValid && !c.isCollapsed) ? c.start : v.text.length;
    if (committedEnd < _sentLen) {
      // 送信済みの部分より前から変換が始まった (通常は起きない)。
      // 送信済みの文字は取り消せないので、位置だけ合わせる。
      _sentLen = committedEnd;
    } else if (committedEnd > _sentLen) {
      // 制御文字は送らない。ことえりは変換中の文字 (Shift+英字で入れた
      // 英字など) を BS で消すと、BS 文字 (U+0008) を確定文字として
      // 入れてくることがある。BS の意図は変換中の文字を消すことなので、
      // X68000 には何も送らない。
      final delta =
          v.text.substring(_sentLen, committedEnd).replaceAll(_controlChars, '');
      _sentLen = committedEnd;
      if (delta.isNotEmpty) {
        debugPrint('[ImeLine] committed: "$delta"');
        _queue.add(delta);
        _pump();
      }
    }

    // 入力欄に残った制御文字は (文字化けして見えるので) すぐ取り除く。
    // 変換中に書き換えると IME と食い違うので、変換中でないときだけ。
    if (!composing && _controlChars.hasMatch(text.text)) {
      final cleaned = text.text.replaceAll(_controlChars, '');
      _sentLen = cleaned.length;
      _clearing = true;
      text.value = TextEditingValue(
        text: cleaned,
        selection: TextSelection.collapsed(offset: cleaned.length),
      );
      _clearing = false;
    }

    if (!composing && text.text.isNotEmpty && _sentLen >= text.text.length) {
      _clearTimer = Timer(_clearDelay, _clearIfIdle);
    }
    notifyListeners();
  }

  void _clearIfIdle() {
    if (composing || _sentLen < text.text.length || text.text.isEmpty) return;
    _clearedText = text.text;
    _clearedAt = DateTime.now();
    _sentLen = 0;
    _clearing = true;
    text.value = TextEditingValue.empty;
    _clearing = false;
    notifyListeners();
  }

  /// 送信中に押された Enter / BS などは、文字列の後に順番どおり送る。
  void enqueueKey(int scancode, {bool ctrl = false}) {
    _queue.add(ctrl ? _CtrlKey(scancode) : scancode);
    _pump();
  }

  Future<void> _pump() async {
    if (_running) return;
    final t = typer;
    if (t == null) return;
    _running = true;
    notifyListeners();
    try {
      while (_queue.isNotEmpty) {
        final item = _queue.removeAt(0);
        if (item is String) {
          _setStatus('送信中: $item');
          final r = await t.typeText(item);
          if (r.skipped > 0) {
            _setStatus('送信: $item (送れない文字 ${r.skipped} 個を省略)',
                clearAfter: _statusHoldSkipped);
          } else {
            _setStatus('送信: $item', clearAfter: _statusHoldOk);
          }
        } else if (item is int) {
          await t.sendOneChar(item, false);
          await Future.delayed(X68kTextTyper.interKeyDelay);
        } else if (item is _CtrlKey) {
          await t.sendCtrlChar(item.scancode);
          await Future.delayed(X68kTextTyper.interKeyDelay);
        }
      }
    } catch (e) {
      _setStatus('エラー: $e', clearAfter: _statusHoldSkipped);
      _queue.clear();
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _statusClearTimer?.cancel();
    _clearTimer?.cancel();
    ImeState.japaneseOn.removeListener(_onImeChanged);
    text.removeListener(_onTextChanged);
    text.dispose();
    focusNode.dispose();
    super.dispose();
  }
}

class ImeLineBar extends StatefulWidget {
  final ImeLineController controller;

  /// バーを閉じたときにフォーカスを戻す先 (キーボード本体の Focus)。
  final FocusNode returnFocusTo;

  const ImeLineBar({
    super.key,
    required this.controller,
    required this.returnFocusTo,
  });

  @override
  State<ImeLineBar> createState() => _ImeLineBarState();
}

class _ImeLineBarState extends State<ImeLineBar> {
  bool _wasVisible = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
    _onChanged();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    final c = widget.controller;
    final visible = c.visible;
    if (visible != _wasVisible) {
      _wasVisible = visible;
      // 表示/非表示の切替後のフレームでフォーカスを移す (TextField がまだ
      // build されていないうちに requestFocus しても効かないため)。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (c.visible) {
          c.focusNode.requestFocus();
        } else {
          widget.returnFocusTo.requestFocus();
        }
      });
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    if (!c.visible) return const SizedBox.shrink();
    return Container(
      color: const Color(0xFF262a30),
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
      child: Row(
        children: [
          const Icon(Icons.translate, size: 18, color: Color(0xFF9E9E9E)),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: c.text,
              focusNode: c.focusNode,
              style: const TextStyle(color: Colors.white, fontSize: 16),
              cursorColor: Colors.white,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                hintText: '日本語入力中: 変換を確定すると X68000 に送信します',
                hintStyle: TextStyle(color: Color(0xFF777777)),
              ),
              // Enter は IM の確定に使われ、確定後は物理キー側が RETURN として
              // 送るので、TextField 側の submit (フォーカスが外れる) は無効化する。
              onEditingComplete: () {},
            ),
          ),
          const SizedBox(width: 12),
          if (c.busy)
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          if (c.status.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 260),
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  c.status,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Color(0xFF9E9E9E), fontSize: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 送信待ちの CTRL + キー。
class _CtrlKey {
  final int scancode;
  const _CtrlKey(this.scancode);
}
