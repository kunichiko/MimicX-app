# MimicX-app 開発メモ

## 概要

スマートフォンから USB-MIDI 経由でマイコンを制御し、レトロ PC の HID デバイスを模倣する Flutter アプリ。

## 技術スタック

| 項目 | 選定 |
|------|------|
| フレームワーク | Flutter (iOS / Android) |
| USB-MIDI ライブラリ | `flutter_midi_command` (pub.dev) |
| プロトコル | MimicX-protocol v0.1.0 |

### flutter_midi_command について

- iOS: CoreMIDI、Android: android.media.midi を使用
- USB-MIDI デバイスの自動検出・接続・送受信が可能
- SysEx 対応済み
- USB-C 接続検出に一部問題の報告あり (issue #136) → 実機で要検証
- バックアップ候補: `libremidi_flutter` (FFI ベース、API 29+ 必要)

## 実装予定の機能

### Phase 1: 基本接続
- [ ] USB-MIDI デバイスの検出・接続
- [ ] SysEx ネゴシエーション (Identify / Capability)
- [ ] デバイスタイプに基づく UI 切り替え

### Phase 2: ジョイスティック UI
- [ ] 仮想ジョイスティック画面 (十字キー + ボタン)
- [ ] タッチ → MIDI Note On/Off 送信
- [ ] ATARI 仕様ジョイスティックのレイアウト

### Phase 3: キーボード UI
- [ ] X68000 キーボードレイアウト表示
- [ ] タッチ → MIDI Note On/Off 送信 (スキャンコード)
- [ ] LED 状態の受信・表示 (かな、CAPS 等)

### Phase 4: 拡張
- [ ] PC-98 キーボードレイアウト
- [ ] マウスエミュレーション
- [ ] キーマップ設定のカスタマイズ

## 運用ドキュメント

- [iOS CI 署名運用メモ](./ci-ios-signing.md) — Apple Development / Distribution
  証明書とプロビジョニングプロファイルの **年次更新手順**。GitHub Actions の
  iOS ビルドで使う Secrets 一覧もここ。

## 接続フロー

```
1. アプリ起動
2. USB-MIDI デバイスを検索
3. デバイス発見 → 接続
4. SysEx IDENTIFY_REQUEST 送信
5. IDENTIFY_RESPONSE 受信 → デバイスタイプ・ターゲット判別
6. SysEx CAPABILITY_REQUEST 送信
7. CAPABILITY_RESPONSE 受信 → 機能情報取得
8. デバイスタイプに応じた UI を表示
9. ユーザー操作 → MIDI メッセージ送信
10. デバイスからの通知 (LED等) → UI に反映
```
