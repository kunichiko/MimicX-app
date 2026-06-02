// ===================================================================================
// ChannelMode をドロップダウンで切り替えながら表示する Scaffold。
//
// 主な責務:
//   - AppBar の title 横に DropdownButton<ChannelMode> を出す (modes.length >= 2 のみ)
//   - 初回 mount で initialMode.onEnter() を呼ぶ
//   - ドロップダウン操作で current.onExit() → setState → next.onEnter() を直列実行
//   - unmount 時に current.onExit() を呼ぶ
//   - 現在モードが buildSettings() を返せば歯車アイコンを表示し、タップで開く
//   - persistenceKey を渡せば最後に選択したモードを SharedPreferences に保存
//
// ChannelMode 自体の dispose は本 Scaffold では行わない (作成側=ページ State が責任)。
// ===================================================================================

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'channel_mode.dart';
import 'l10n/app_localizations.dart';
import 'midi_service.dart';

class ModeScaffold extends StatefulWidget {
  final String title;

  /// AppBar に title の下に小さく表示するサブタイトル (アダプタ名など)。空/null なら非表示。
  final String? subtitle;
  final MidiService midi;
  final List<ChannelMode> modes;

  /// 設定 SharedPreferences に「最後に選択したモードの id」を保存するキー。
  /// null なら永続化しない。
  final String? persistenceKey;

  /// AppBar の actions 末尾に追加するウィジェット (設定アイコン以外のページ独自項目)。
  final List<Widget> extraActions;

  const ModeScaffold({
    super.key,
    required this.title,
    this.subtitle,
    required this.midi,
    required this.modes,
    this.persistenceKey,
    this.extraActions = const [],
  }) : assert(modes.length > 0, 'modes must contain at least one ChannelMode');

  @override
  State<ModeScaffold> createState() => _ModeScaffoldState();
}

class _ModeScaffoldState extends State<ModeScaffold> {
  late ChannelMode _current;
  // モード切替中フラグ。連打で同時に onEnter/onExit が走らないようガード。
  bool _switching = false;

  @override
  void initState() {
    super.initState();
    _current = widget.modes.first;
    // 初期 mount での onEnter / 永続化された選択モードの復元を順次実行。
    // build より後に走らせたいので microtask で。
    Future.microtask(_initialize);
  }

  Future<void> _initialize() async {
    final restored = await _restorePersistedMode();
    if (restored != null && restored != _current) {
      if (mounted) setState(() => _current = restored);
    }
    final err = await _current.onEnter(widget.midi);
    if (err != null && mounted) {
      _showEnterError(_current, err);
    }
  }

  /// onEnter 失敗時に Snackbar でユーザーに通知する。
  /// モード側が `enterErrorHint` でヒント文を返した場合は改行で続けて表示する。
  void _showEnterError(ChannelMode mode, String reason) {
    final l = AppLocalizations.of(context);
    if (l == null) return;
    final base = l.padModeSwitchFailed(mode.label(context), reason);
    final hint = mode.enterErrorHint(context, reason);
    final text = hint != null ? '$base\n$hint' : base;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text)),
    );
  }

  Future<ChannelMode?> _restorePersistedMode() async {
    final key = widget.persistenceKey;
    if (key == null) return null;
    final prefs = await SharedPreferences.getInstance();
    final savedId = prefs.getString(key);
    if (savedId == null) return null;
    for (final m in widget.modes) {
      if (m.id == savedId) return m;
    }
    return null;
  }

  Future<void> _persistSelectedMode(ChannelMode mode) async {
    final key = widget.persistenceKey;
    if (key == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, mode.id);
  }

  Future<void> _switchTo(ChannelMode next) async {
    if (_switching || next == _current) return;
    setState(() => _switching = true);
    final previous = _current;
    try {
      await previous.onExit(widget.midi);
      if (!mounted) return;
      setState(() => _current = next);
      // 旧モードの TextField 等が握っていた primary focus を一度落とす。
      // (ExcludeFocus でドロップダウンが focus を持てなくしてあるので、
      // ここで unfocus すれば次フレームで新 body の autofocus が拾える)。
      FocusManager.instance.primaryFocus?.unfocus();
      final err = await next.onEnter(widget.midi);
      if (err != null) {
        // 切替失敗: Snackbar 表示 + 前モードへロールバック
        if (mounted) _showEnterError(next, err);
        if (mounted) setState(() => _current = previous);
        await previous.onEnter(widget.midi);
        return;
      }
      await _persistSelectedMode(next);
    } finally {
      // _switching を setState 経由で戻す。setState を使わないと、ACK 待ちで
      // 関数全体が 1 フレームを超えた場合に途中の rebuild が _switching=true を
      // 捕まえてしまい、最終的に false に戻った後も再 build されず、
      // ドロップダウンが永続的に disabled になる。
      if (mounted) {
        setState(() => _switching = false);
      } else {
        _switching = false;
      }
    }
  }

  @override
  void dispose() {
    // 非同期 dispose は呼べないので fire-and-forget で onExit を投げる。
    // この時点で widget は unmount 済み → setState は呼ばれない。
    _current.onExit(widget.midi);
    super.dispose();
  }

  Widget _buildModeSelector() {
    if (widget.modes.length < 2) return const SizedBox.shrink();
    // AppBar・ポップアップともに surface 系の背景なので、テキストとアイコンは
    // onSurface 系で揃える (onPrimary だと dark テーマで暗い青になり潰れる)。
    final colors = Theme.of(context).colorScheme;
    // 戻るボタンと同じ理由で ExcludeFocus でフォーカスチェーンから外す。
    // ライン入力モード (TextField を持つ) から標準モードに切り替えた直後に
    // この DropdownButton が primary focus を握り続けてしまい、RETURN キー
    // でドロップダウンが再展開されたり、X68k 側に RETURN が届かない問題を
    // 防ぐ。マウスクリックでの切替は focus を要求しないので動作はそのまま。
    return ExcludeFocus(
      child: DropdownButtonHideUnderline(
        child: DropdownButton<ChannelMode>(
          value: _current,
          dropdownColor: colors.surfaceContainerHigh,
          iconEnabledColor: colors.onSurface,
          style: TextStyle(
            color: colors.onSurface,
            fontSize: 14,
          ),
          items: [
            for (final m in widget.modes)
              DropdownMenuItem<ChannelMode>(
                value: m,
                child: Text(m.label(context)),
              ),
          ],
          onChanged: _switching
              ? null
              : (m) {
                  if (m != null) _switchTo(m);
                },
        ),
      ),
    );
  }

  void _openSettings(Widget sheet) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (_) => sheet,
    );
  }

  @override
  Widget build(BuildContext context) {
    // 現在モードが notifyListeners() を呼べば AppBar / body を含めて rebuild する。
    return AnimatedBuilder(
      animation: _current,
      builder: (context, _) {
        final settingsSheet = _current.buildSettings(context);
        return Scaffold(
          appBar: AppBar(
            // 自動生成の戻るボタンにフォーカスが移って Enter で誤 activate
            // される事故 (macOS の Cocoa Ctrl+M = Enter 経由など) を防ぐため、
            // ExcludeFocus でフォーカスチェーンから外す。マウスクリックは
            // フォーカス不要なので「戻る」機能は維持される。
            leading: Navigator.of(context).canPop()
                ? const ExcludeFocus(child: BackButton())
                : null,
            title: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.title, overflow: TextOverflow.ellipsis),
                      if (widget.subtitle != null &&
                          widget.subtitle!.isNotEmpty)
                        Text(
                          widget.subtitle!,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
                if (widget.modes.length >= 2) ...[
                  const SizedBox(width: 12),
                  _buildModeSelector(),
                ],
              ],
            ),
            actions: [
              ..._current.buildActions(context),
              if (settingsSheet != null)
                IconButton(
                  icon: const Icon(Icons.tune),
                  tooltip: AppLocalizations.of(context)!.controllerSettings,
                  onPressed: () => _openSettings(settingsSheet),
                ),
              ...widget.extraActions,
            ],
          ),
          body: _current.buildBody(context, widget.midi),
        );
      },
    );
  }
}
