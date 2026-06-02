// ===================================================================================
// device_nickname_store.dart
// ===================================================================================
// アダプタ個体 (Chip UID 由来の 16 文字 serial) ごとにユーザーがつけたニックネームを
// 端末ローカルの SharedPreferences に保存する。
//
// キー: "device_nickname:<serial>"  (例: "device_nickname:CDABD82C27BDCC95")
// 値:   ユーザー入力文字列 (UI 側で max 50 文字に制限する)
//
// 同期 (cloud sync) は想定しない。リセット/再インストールでクリア。
// ===================================================================================

import 'package:shared_preferences/shared_preferences.dart';

class DeviceNicknameStore {
  static const String _prefix = 'device_nickname:';

  /// 指定 [serial] のニックネームを取得。未設定なら null。
  static Future<String?> get(String serial) async {
    if (serial.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString('$_prefix$serial');
    if (v == null || v.isEmpty) return null;
    return v;
  }

  /// ニックネームを設定。空文字を渡すと削除と同等。
  static Future<void> set(String serial, String nickname) async {
    if (serial.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    final trimmed = nickname.trim();
    if (trimmed.isEmpty) {
      await prefs.remove('$_prefix$serial');
    } else {
      await prefs.setString('$_prefix$serial', trimmed);
    }
  }

  /// 削除。
  static Future<void> delete(String serial) async {
    if (serial.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$serial');
  }
}
