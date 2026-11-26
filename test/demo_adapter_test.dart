import 'package:flutter_test/flutter_test.dart';
import 'package:mimicx/demo_adapter.dart';
import 'package:mimicx/protocol.dart';

/// [DemoAdapter] に [bytes] を渡し、応答 (遅延あり) を集めて返す。
Future<List<List<int>>> _exchange(DemoAdapter a, List<int> bytes) async {
  final replies = <List<int>>[];
  a.onReply = replies.add;
  a.receive(bytes);
  await Future<void>.delayed(const Duration(milliseconds: 50));
  return replies;
}

void main() {
  test('IDENTIFY_RESPONSE はアプリのパーサで読めて接続可能な版数を申告する', () async {
    final a = DemoAdapter(DemoAdapterKind.combined);
    final replies = await _exchange(a, SysExBuilder.identifyRequest());
    expect(replies, hasLength(1));
    final id = DeviceIdentity.parse(replies.single);
    expect(id, isNotNull);
    expect(MinSupportedProtocol.meets(id!.protocolMajor, id.protocolMinor), isTrue);
    expect(
      MinSupportedProtocol.isNewerThanKnown(id.protocolMajor, id.protocolMinor),
      isFalse,
    );
    expect(id.serial, a.serial);
    expect(id.deviceName, a.name);
    expect(id.channels.map((c) => c.hidType),
        [HidType.joystick, HidType.keyboard, HidType.mouse]);
  });

  test('HEART_BEAT には req_id を保った ACK OK を返す', () async {
    final a = DemoAdapter(DemoAdapterKind.joystick);
    final replies = await _exchange(a, SysExBuilder.heartBeat(0x2A));
    expect(replies.single, [
      0xF0, 0x7D, 0x01, SysExBuilder.cmdAck, 0x2A, AckStatus.ok,
      SysExBuilder.cmdHeartBeat, 0xF7,
    ]);
  });

  test('未対応コマンド (BRIDGE_LINK_INFO) は UNKNOWN_COMMAND', () async {
    final a = DemoAdapter(DemoAdapterKind.joystick);
    final replies = await _exchange(a, SysExBuilder.bridgeLinkInfo(5));
    expect(replies.single[5], AckStatus.unknownCommand);
  });

  test('X68000: 0xFF 問い合わせと CAPS 押下で LED 制御コマンドを返す', () async {
    final a = DemoAdapter(DemoAdapterKind.x68000);
    // note 0x7F の note off (ch2 = 0-indexed 1) → 全消灯の LED コマンド 0xFF
    var replies = await _exchange(a, [0x81, 0x7F, 0x00]);
    expect(replies.single, [0xF0, 0x7D, 0x01, SysExBuilder.cmdTargetRx, 1, 0x0F, 0x0F, 0xF7]);
    // CAPS (0x5D = bit3) 押下 → bit3 が 0 (点灯) になる: 0xF7
    replies = await _exchange(a, [0x91, 0x5D, 0x7F]);
    expect(replies.single.sublist(4, 7), [1, 0x0F, 0x07]);
    // 他チャンネル (ジョイスティック) のノートには応答しない
    replies = await _exchange(a, [0x90, 0x5D, 0x7F]);
    expect(replies, isEmpty);
  });
}
