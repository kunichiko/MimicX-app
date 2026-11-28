import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mimicx/ime_line_bar.dart';

TextEditingValue _v(String text, [int? cs, int? ce]) => TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
      composing: cs == null ? TextRange.empty : TextRange(start: cs, end: ce!),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('「ありがとう」変換中に「。」を押しても二重に送らない', () {
    final c = ImeLineController();
    c.text.value = _v('ありがとう', 0, 5); // 変換中
    expect(c.pendingTexts, isEmpty);
    expect(c.bufferEmpty, isFalse);
    c.text.value = _v('ありがとう'); // 「。」で前を確定
    c.text.value = _v('ありがとう。', 5, 6); // 続けて「。」を変換中
    expect(c.pendingTexts, ['ありがとう']);
    c.text.value = _v('ありがとう。'); // 「。」を確定
    expect(c.pendingTexts, ['ありがとう', '。']);
    expect(c.bufferEmpty, isTrue);
    c.dispose();
  });

  test('前の確定と次の変換開始が 1 回で届いても差分だけ送る', () {
    final c = ImeLineController();
    c.text.value = _v('こんにちは', 0, 5);
    c.text.value = _v('こんにちは。', 5, 6);
    expect(c.pendingTexts, ['こんにちは']);
    c.text.value = _v('こんにちは。');
    expect(c.pendingTexts, ['こんにちは', '。']);
    c.dispose();
  });

  test('変換中の「A」を BS で消したときの BS 文字 (U+0008) は送らず消す', () {
    final c = ImeLineController();
    c.text.value = _v('A', 0, 1); // Shift+A で変換中
    c.text.value = _v('\u0008'); // BS で ことえりが U+0008 を確定してくる
    expect(c.pendingTexts, isEmpty);
    expect(c.text.text, isEmpty);
    expect(c.bufferEmpty, isTrue);
    c.text.value = _v('か', 0, 1);
    c.text.value = _v('家');
    expect(c.pendingTexts, ['家']);
    c.dispose();
  });

  test('空にした直後に古い内容の更新が来ても再送しない', () async {
    final c = ImeLineController();
    c.text.value = _v('日');
    expect(c.pendingTexts, ['日']);
    await Future<void>.delayed(const Duration(milliseconds: 900)); // 空にされる
    expect(c.text.text, isEmpty);
    c.text.value = _v('日に', 1, 2); // 空にする前の内容から続く更新
    c.text.value = _v('日二');
    expect(c.pendingTexts, ['日', '二']);
    c.dispose();
  });
}
