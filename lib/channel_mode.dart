// ===================================================================================
// 1 つの MIDI チャンネル (= 1 つの仮想 HID デバイス) に対して、複数の UI 変種を
// 切り替えるための抽象。
//
// たとえば「ATARI Joystick」というチャンネルでも:
//   - 2 ボタンモード (A/B)
//   - MD 6B モード (A/B/C + X/Y/Z)
//   - 将来追加される特殊パッドモード
// のように複数の UI を提供できる。本クラスはそれらを統一的に扱うインターフェース。
//
// ChannelMode は以下を提供する:
//   - id              : 永続化キーとして使う安定文字列
//   - label(ctx)      : ドロップダウン表示用のローカライズ済みラベル
//   - onEnter / onExit: モード切替時の前後処理 (SysEx でファームのモード変更等)
//   - buildBody       : このモードの操作 UI 本体
//   - buildSettings?  : 設定シート (null なら歯車アイコン非表示)
//   - dispose         : このモードが保持するリソースの解放 (ChangeNotifier 等)
// ===================================================================================

import 'package:flutter/material.dart';
import 'midi_service.dart';

/// 1 つの ChannelMode は 1 つの仮想 HID のひとつの UI 変種を表す。
///
/// [ChangeNotifier] を継承しているので、モード自身が抱える状態 (例: テンキー
/// 表示の ON/OFF) を変更したら [notifyListeners] を呼ぶことで、ホスト Scaffold
/// が AppBar / body を rebuild する。
abstract class ChannelMode extends ChangeNotifier {
  /// 永続化に使う安定 ID (例: "joystick.atari", "joystick.md6")。
  String get id;

  /// ドロップダウンに表示するローカライズ済みラベル。
  String label(BuildContext context);

  /// このモードがアクティブになった時 (ページ初期 mount または別モードからの切替) に
  /// 呼ばれる。ファームウェアにモード切替コマンドを送るような処理をここに書く。
  ///
  /// 戻り値 null = 成功、非 null = 失敗 (ユーザー向けエラー本文)。
  /// 失敗時、ModeScaffold は Snackbar を出して前のモードへロールバックする。
  Future<String?> onEnter(MidiService midi) async => null;

  /// このモードを抜ける時 (別モードに切替 / ページ unmount) に呼ばれる。
  Future<void> onExit(MidiService midi) async {}

  /// このモードを載せている画面のアクティブ (前面表示) 状態が変わったときに
  /// 呼ばれる。Combined セッションでは複数ページが同時に生存するため、画面の
  /// 向き (OrientationHelper) や IME 有効化のような「前面の 1 画面だけが持つべき
  /// 副作用」はここで active に応じて適用する (onEnter は 1 回だけの副作用専用)。
  /// 単機能ページでは常に active=true で 1 度呼ばれる。既定は何もしない。
  void onActiveChanged(bool active, MidiService midi) {}

  /// このモードの操作 UI 本体。Scaffold.body に挿入される想定。
  Widget buildBody(BuildContext context, MidiService midi);

  /// 設定シート Widget。null なら歯車アイコンを表示しない。
  Widget? buildSettings(BuildContext context) => null;

  /// このモード固有の AppBar アクション (歯車以外)。デフォルトは空。
  /// テンキー表示トグルなどモード固有のトグル類はここで返す。
  List<Widget> buildActions(BuildContext context) => const [];

  /// `onEnter` がエラーを返したときの SnackBar に併記するヒント文 (例: ファーム
  /// 未対応の場合の更新依頼)。デフォルトは null (ヒントなし)。
  /// `reason` は `onEnter` が返したエラー文字列 (ACK status のラベル等)。
  String? enterErrorHint(BuildContext context, String reason) => null;
}
