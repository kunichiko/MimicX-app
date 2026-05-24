// ===================================================================================
// X68000 → キーボード TARGET_RX 受信ログ画面
// ===================================================================================
// X68kKeyboardSharedState が保持する直近 100 件のログをスクロール表示する。
// newest first で、各行 1 行に [時刻] [生 HEX] [意味] を等幅で並べる。
// AppBar の履歴ボタンから push する。
// ===================================================================================
import 'package:flutter/material.dart';
import 'x68k_shared_state.dart';

class X68kTargetRxLogPage extends StatelessWidget {
  final X68kKeyboardSharedState shared;

  const X68kTargetRxLogPage({super.key, required this.shared});

  static String _formatTime(DateTime t) {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.${three(t.millisecond)}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('受信ログ'),
        actions: [
          IconButton(
            tooltip: 'クリア',
            icon: const Icon(Icons.delete_sweep),
            onPressed: shared.clearLog,
          ),
        ],
      ),
      // 横向き運用なので左右ノッチ / ホームインジケータを避けるため SafeArea で囲む。
      body: SafeArea(
        child: ListenableBuilder(
          listenable: shared,
          builder: (context, _) {
            final entries = shared.log;
            if (entries.isEmpty) {
              return const Center(
                child: Text('まだ受信していません',
                    style: TextStyle(color: Colors.grey)),
              );
            }
            // newest first; 1 行表示 [時刻] [0xHH] [意味]
            return ListView.builder(
              itemCount: entries.length,
              // index 0 = newest になるよう逆順アクセス
              itemBuilder: (context, index) {
                final e = entries[entries.length - 1 - index];
                final hex = e.rawByte
                    .toRadixString(16)
                    .padLeft(2, '0')
                    .toUpperCase();
                return Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      SizedBox(
                        width: 110,
                        child: Text(
                          _formatTime(e.timestamp),
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 12,
                            color: Colors.grey,
                          ),
                        ),
                      ),
                      SizedBox(
                        width: 56,
                        child: Text(
                          '0x$hex',
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          e.interpretation,
                          style: const TextStyle(fontSize: 13),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
