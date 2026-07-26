import 'package:flutter_test/flutter_test.dart';
import 'package:mimicx/joystick_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  JoystickSettings makeSettings() => JoystickSettings(
        prefix: 'joystick.test',
        defaultPadAssign: const {'south': 6, 'east': 7},
      );

  test('未設定時はモード既定の割り当て + turboNotes を反映して返す', () async {
    SharedPreferences.setMockInitialValues({
      'joystick.test.turboNotes': ['6'],
    });
    final s = makeSettings();
    await s.load();

    expect(s.padAssign('south').note, 6);
    expect(s.padAssign('south').turbo, isTrue); // turboNotes(6) に追従
    expect(s.padAssign('east').note, 7);
    expect(s.padAssign('east').turbo, isFalse);
    expect(s.padAssign('l1').note, isNull); // 既定なし = None
    expect(s.padAssign('l1').turbo, isFalse);
  });

  test('setPadAssign で全コントロールが materialize され turboNotes と独立になる', () async {
    SharedPreferences.setMockInitialValues({
      'joystick.test.turboNotes': ['6'],
    });
    final s = makeSettings();
    await s.load();

    // west に A(6) を連射付きで割り当て
    await s.setPadAssign('west', const PadButtonAssign(6, true));
    expect(s.padAssign('west').note, 6);
    expect(s.padAssign('west').turbo, isTrue);
    // materialize 済みの south は元の turboNotes 反映値を保持
    expect(s.padAssign('south').turbo, isTrue);

    // 以降 turboNotes を変えてもゲームパッド割り当てには影響しない
    await s.setTurbo(6, false);
    expect(s.padAssign('south').turbo, isTrue);
    expect(s.padAssign('west').turbo, isTrue);
  });

  test('保存フォーマットの往復 (note なしは "-")', () async {
    SharedPreferences.setMockInitialValues({});
    final s1 = makeSettings();
    await s1.load();
    await s1.setPadAssign('l1', const PadButtonAssign(9, false));
    await s1.setPadAssign('r1', const PadButtonAssign(null, true)); // turbo は無効化される

    final s2 = makeSettings();
    await s2.load();
    expect(s2.padAssign('l1').note, 9);
    expect(s2.padAssign('l1').turbo, isFalse);
    expect(s2.padAssign('r1').note, isNull);
    expect(s2.padAssign('r1').turbo, isFalse); // note なしの turbo は保存されない
    // materialize された既定値も往復している
    expect(s2.padAssign('south').note, 6);
  });
}
