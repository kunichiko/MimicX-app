import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// ジョイスティック画面の操作設定。
///
/// モードごとに 1 インスタンス持つ前提で、コンストラクタの [prefix] を
/// SharedPreferences キーの接頭辞にする (例: "joystick.atari")。
/// load() が呼ばれた時点で永続化値があれば読み込み、無ければ
/// v1.0.5 までの非プレフィックスキー (`js_*`) をフォールバックとして使う。
///
/// ChangeNotifier を継承しているので、画面側は addListener で再描画フックできる。
class JoystickSettings extends ChangeNotifier {
  final String prefix;

  JoystickSettings({required this.prefix});

  // 新キー (prefixed)
  String get _kDeadZoneRatio => '$prefix.deadZoneRatio';
  String get _kExtraHitRadius => '$prefix.extraHitRadius';
  String get _kTurboNotes => '$prefix.turboNotes';
  String get _kTurboRate => '$prefix.turboRate';
  String get _kTownsPad => '$prefix.townsPad';

  // v1.0.5 までの旧キー (どのモードでもなく単一インスタンスだった時代)。
  // 既存ユーザの設定を引き継ぐため、新キーが無い場合のフォールバックに使う。
  static const String _legacyDeadZoneRatio = 'js_dead_zone_ratio';
  static const String _legacyExtraHitRadius = 'js_extra_hit_radius';
  static const String _legacyTurboNotes = 'js_turbo_notes';
  static const String _legacyTurboRate = 'js_turbo_rate';

  /// 不感エリア半径のデフォルト (D-pad サイズに対する比率, 0.0〜0.4)
  static const double defaultDeadZoneRatio = 0.15;

  /// ボタンヒット判定半径への加算量のデフォルト (px, 0〜40)
  /// 大きくすると隣接ボタンとオーバーラップして同時押し / スライド遷移ができる。
  static const double defaultExtraHitRadius = 20.0;

  /// 連射速度のデフォルト (Hz, 1.0〜30.0)。1 Hz = 1 秒間に 1 回 press。
  static const double defaultTurboRate = 10.0;

  bool _loaded = false;
  double _deadZoneRatio = defaultDeadZoneRatio;
  double _extraHitRadius = defaultExtraHitRadius;
  Set<int> _turboNotes = const <int>{};
  double _turboRate = defaultTurboRate;
  bool _townsPad = true;

  bool get loaded => _loaded;
  double get deadZoneRatio => _deadZoneRatio;
  double get extraHitRadius => _extraHitRadius;

  /// TOWNS パッド機能 (ATARI モードのみ意味を持つ)。ON のとき RUN/SELECT ボタンを
  /// UI に表示し、ゲームパッドの Start/Back を RUN/SELECT ノートにマップする。
  /// 旧ファームはノートを無視するだけなのでデフォルト ON。
  bool get townsPad => _townsPad;

  /// 連射が有効になっている note 番号の集合 (読み取り専用ビュー)。
  Set<int> get turboNotes => Set.unmodifiable(_turboNotes);
  bool isTurbo(int note) => _turboNotes.contains(note);

  /// 連射速度 (Hz, 全ボタン共通)。
  double get turboRate => _turboRate;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();

    _deadZoneRatio = prefs.getDouble(_kDeadZoneRatio) ??
        prefs.getDouble(_legacyDeadZoneRatio) ??
        defaultDeadZoneRatio;
    _extraHitRadius = prefs.getDouble(_kExtraHitRadius) ??
        prefs.getDouble(_legacyExtraHitRadius) ??
        defaultExtraHitRadius;
    _turboRate = prefs.getDouble(_kTurboRate) ??
        prefs.getDouble(_legacyTurboRate) ??
        defaultTurboRate;

    final notes = prefs.getStringList(_kTurboNotes) ??
        prefs.getStringList(_legacyTurboNotes) ??
        const <String>[];
    _turboNotes = notes.map(int.parse).toSet();

    _townsPad = prefs.getBool(_kTownsPad) ?? true;

    _loaded = true;
    notifyListeners();
  }

  Future<void> setDeadZoneRatio(double v) async {
    if (_deadZoneRatio == v) return;
    _deadZoneRatio = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kDeadZoneRatio, v);
  }

  Future<void> setExtraHitRadius(double v) async {
    if (_extraHitRadius == v) return;
    _extraHitRadius = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kExtraHitRadius, v);
  }

  Future<void> setTurbo(int note, bool enabled) async {
    final next = Set<int>.from(_turboNotes);
    if (enabled) {
      if (!next.add(note)) return;
    } else {
      if (!next.remove(note)) return;
    }
    _turboNotes = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _kTurboNotes,
      _turboNotes.map((e) => e.toString()).toList(),
    );
  }

  Future<void> setTurboRate(double v) async {
    if (_turboRate == v) return;
    _turboRate = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_kTurboRate, v);
  }

  Future<void> setTownsPad(bool v) async {
    if (_townsPad == v) return;
    _townsPad = v;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kTownsPad, v);
  }
}
