// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Japanese (`ja`).
class AppLocalizationsJa extends AppLocalizations {
  AppLocalizationsJa([String locale = 'ja']) : super(locale);

  @override
  String get appTitle => 'Mimic X';

  @override
  String get homeRescanTooltip => '再スキャン';

  @override
  String get homeAboutTooltip => 'アプリについて';

  @override
  String get homeSearching => 'アダプタを検索中…';

  @override
  String get homeConnecting => 'アダプタに接続中…';

  @override
  String get homeNoDevicesTitle => 'アダプタが見つかりません';

  @override
  String get homeNoDevicesHint => 'Mimic X アダプタを接続して、右上のリロードボタンを押してください';

  @override
  String get homeIncompatibleNote => 'Mimic X 非対応 (応答なし)';

  @override
  String homeFirmwareVersion(String fwVersion, String protoVersion) {
    return 'fw $fwVersion (proto $protoVersion)';
  }

  @override
  String homeChannelLabel(int channel, String target) {
    return 'CH$channel - $target';
  }

  @override
  String get deviceNotResponding => 'アダプタから応答がありません (Mimic X 互換ではない可能性)';

  @override
  String get noChannelsAvailable => '使用可能なチャンネルがありません';

  @override
  String unsupportedFunction(String hidType, String target) {
    return '未対応の機能です: $hidType / $target';
  }

  @override
  String protocolTooOld(String deviceVersion, String minVersion) {
    return 'ファームウェアが古すぎます (proto $deviceVersion, 要 $minVersion 以上)。アダプタを更新してください';
  }

  @override
  String get protocolNewerWarningTitle => '互換性がない可能性があります';

  @override
  String protocolNewerWarningBody(String deviceVersion, String knownVersion) {
    return 'ファームウェアのプロトコルバージョン (proto $deviceVersion) がアプリが知っている最新版 (proto $knownVersion) より新しいです。アプリを最新に更新することを推奨します。';
  }

  @override
  String padModeSwitchFailed(String mode, String reason) {
    return '$mode モードへの切替に失敗しました ($reason)';
  }

  @override
  String get selectFunction => '使用する機能を選択';

  @override
  String get joystickTitle => 'Joystick';

  @override
  String get controllerSettings => '操作設定';

  @override
  String get padModeAtari => 'ATARI';

  @override
  String get padModeMd6 => 'MD 6B';

  @override
  String get padModeLibbleRabble => 'リブルラブル';

  @override
  String get padModeMsxMouse => 'MSX マウス';

  @override
  String get msxMouseFirmwareUpdateHint =>
      'ファームウェアが MSX マウスに未対応の可能性があります。ファームウェアを更新してください。';

  @override
  String deadZoneLabel(int percent) {
    return '方向キー不感エリア半径: $percent%';
  }

  @override
  String get deadZoneHelp => '小さいほど少ない指の動きで方向が反応する。0% は中央でも常時いずれかが押された状態になる。';

  @override
  String extraHitLabel(int px) {
    return 'ボタンヒット範囲拡張: +$px px';
  }

  @override
  String get extraHitHelp =>
      '大きくすると隣接ボタンとオーバーラップし、指の腹での同時押しや A→B のスライド遷移ができるようになる。';

  @override
  String turboRateLabel(int hz) {
    return '連射速度: $hz Hz';
  }

  @override
  String get turboRateHelp => '1 秒間に発火するボタン押下回数。下の連射 ON/OFF を有効にしたボタンに適用される。';

  @override
  String get turboToggleSection => '連射 ON/OFF (画面ボタン)';

  @override
  String get turboToggleHelp =>
      '有効にしたボタンは押している間、上の連射速度で press / release を繰り返す。';

  @override
  String get turboBadge => '連';

  @override
  String get padAssignSection => 'ゲームパッドのボタン割り当て';

  @override
  String get padAssignNone => 'なし';

  @override
  String get padAssignHelp =>
      'コントローラーのボタンを押すと該当行が光ります。「連」チップでボタンごとの連射を設定できます (速度は上の連射速度と共通)。';

  @override
  String get bleWinPairingHintTitle => '接続できません';

  @override
  String get bleWinPairingHintBody =>
      'アダプタとの BLE 接続が繰り返し失敗しました。ファームウェア更新 (erase 付き書き込み) などでアダプタ側のペアリング情報が消えている可能性があります。\n\nWindows の [設定] > [Bluetooth とデバイス] からこのアダプタ (MimicX) を削除し、もう一度接続してみてください。';

  @override
  String get townsPadLabel => 'TOWNSパッド機能 (RUN/SELECT)';

  @override
  String get townsPadHelp =>
      '画面に RUN / SELECT ボタンを表示し、ゲームパッドの Start / Back を割り当てる。RUN は左右同時、SELECT は上下同時としてターゲット機に出力される (ファームウェア v1.1.0 以降)。';

  @override
  String get x68kKeyboardTitle => 'X68000 Keyboard';

  @override
  String get deviceRenameTooltip => '名前を変更';

  @override
  String get deviceRenameTitle => 'アダプタの名前を変更';

  @override
  String get deviceRenameHint => 'ニックネーム (最大 50 文字)';

  @override
  String deviceRenameSerialLabel(String serial) {
    return 'シリアル: $serial';
  }

  @override
  String get deviceRenameSaveButton => '保存';

  @override
  String get deviceRenameClearButton => '規定値に戻す';

  @override
  String get deviceRenameConnecting => '接続中…';

  @override
  String get deviceRenameConnectFailed => '名前変更のための接続に失敗しました。';

  @override
  String get connectionLost => 'アダプタとの通信が途絶えました。再スキャンします。';

  @override
  String get aboutTitle => 'このアプリについて';

  @override
  String get aboutAppDescription =>
      'Mimic X アダプタを介して、スマートフォンをレトロ PC (X68000 / MSX等) のジョイスティックやキーボードとして使うための USB-MIDI コントローラアプリです。';

  @override
  String aboutVersion(String version, String build) {
    return 'バージョン $version ($build)';
  }

  @override
  String get aboutLicensesButton => 'オープンソースライセンス';

  @override
  String get aboutCopyright => '© 2026 Kunihiko Ohnaka';

  @override
  String get switchToKeyboard => 'キーボード画面へ切替';

  @override
  String get switchToJoystick => 'ジョイスティック画面へ切替';
}
