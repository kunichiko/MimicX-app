# Mimic X app

**製品名: Mimic X - smart retro PC HID**

Mimic X とは、スマートフォン（iOS/Android）からUSB-MIDI経由でマイコンを制御し、レトロPCのHIDデバイス（キーボード・マウス・ジョイスティック）を模倣するハード及びアプリ群です。
Mimic X appは、Flutterで作られたマルチプラットフォームアプリで、以下のプラットフォームで動作します。

* iOS
* Android
* macOS
* Windows

「Mimic X」コントローラーアプリは、様々なレトロデバイスに変身可能です。

## 機能

- ジョイスティックモード: 画面上の仮想ジョイスティックで操作
  - ATARI 2 ボタン互換
  - メガドライブ 6 ボタンファイティングパッド互換
- キーボードモード: レトロPCのキーボードレイアウトを再現し、タイプ入力が可能
- レトロPC本体からの信号受信（キーボードLED制御など）に対応

## 開発環境

Flutter SDK のバージョンは [`.fvmrc`](./.fvmrc) で固定 (現在 3.38.5)。
[FVM](https://fvm.app/) を使ってバージョンを揃えるのが推奨。

```sh
# 初回 clone 後
brew install fvm           # 未インストールなら
fvm install                # .fvmrc に書かれたバージョンを取得
fvm flutter pub get
fvm flutter run
```

VS Code / Android Studio から開く場合は Flutter SDK の path を `.fvm/flutter_sdk`
に向けるか、シェルで `fvm flutter ...` を使う。

## 開発フロー (git-flow ベース)

ブランチ運用は [A successful Git branching model (Vincent Driessen)](https://nvie.com/posts/a-successful-git-branching-model/)
に倣った構成。

- **`main`**: リリース版。直接 push は禁止、PR 経由のみ。merge commit
  (`--no-ff`) で develop からのリリースを取り込む。タグ打ちもこのブランチに対して。
- **`develop`**: 開発統合ブランチ。日常の開発 commit はここに積む。`main` の
  祖先関係を維持するので force push / reset は行わない (= 他人が `develop` を
  base にした PR を立てても破綻しない)。
- **feature ブランチ** (任意): 大きな変更や複数 commit に渡る作業は
  `feature/<name>` を切って `develop` への PR を立てる。

### コントリビュータ向け

外部からの PR は `develop` を base にしてください (リリース直前の hotfix のみ
`main` を base にして直接 PR でも OK)。

## リリース手順

タグを起点に GitHub Actions が自動でビルド・署名し、成果物を
GitHub Releases と Actions artifacts に登録する流れ。
Android APK / AAB、macOS ZIP、Windows ZIP は GitHub Release に添付され、
iOS IPA / xcarchive は Actions artifacts として取得する。

### 1. develop → main を merge

```sh
# develop に積まれた変更で release できる状態になったら
# GitHub UI で develop → main の PR を作成 → "Create a merge commit" で merge
# (Squash / Rebase は無効化済み。Merge commit のみ)

git checkout main && git pull             # merge commit を取り込む
git checkout develop                      # reset 不要 (祖先関係維持)
```

### 2. main で `pubspec.yaml` の version を更新

```yaml
version: 1.2.3+1   # X.Y.Z 部分が tag と一致する必要あり
```

`+N` (build 番号) は CI で `GITHUB_RUN_NUMBER` に上書きされるので何でもよい
(慣習で `+1` のまま放置)。

```sh
git add pubspec.yaml
git commit -m "v1.2.3 リリース"
git push
```

### 3. tag を打って push

```sh
git tag -a v1.2.3 -m "Release v1.2.3" && git push origin v1.2.3
```

GitHub Actions の `Release Build` workflow が tag push を検知 → pubspec と
tag の整合性を検証 → flutter build → 署名 → アーティファクト出力。
**version が不一致だと CI が即 fail する** ので、その場合は pubspec を直して
tag を打ち直す (`git tag -d v1.2.3 && git push origin :v1.2.3` で削除してから
再 tag)。

### 4. アーティファクトを確認

GitHub Actions の `Release Build` が成功すると、tag と同名の GitHub Release に
Android APK / AAB、macOS ZIP、Windows ZIP が添付される。iOS IPA / xcarchive は
workflow run の Artifacts からダウンロードする。

必要に応じて `workflow_dispatch` から `all` / `android` / `ios` / `macos` /
`windows` を選び、手動ビルドも実行できる。

### GitHub Actions Secrets

Android の release 署名には次の Secrets が必要:

- `ANDROID_KEYSTORE_BASE64`
- `ANDROID_KEYSTORE_PASSWORD`
- `ANDROID_KEY_ALIAS`
- `ANDROID_KEY_PASSWORD`

iOS の ad-hoc archive export には次の Secrets が必要:

- `APPLE_TEAM_ID`
- `IOS_CERTIFICATE_BASE64`
- `IOS_CERTIFICATE_PASSWORD`
- `IOS_PROVISIONING_PROFILE_BASE64`
- `KEYCHAIN_PASSWORD`

TestFlight / App Store Connect へアップロードする場合は、追加で次の Secrets が必要:

- `IOS_APP_STORE_PROVISIONING_PROFILE_BASE64`
- `APPSTORE_ISSUER_ID`
- `APPSTORE_KEY_ID`
- `APPSTORE_PRIVATE_KEY`

macOS の署名証明書を使う場合は次の Secrets を追加する:

- `MACOS_CERTIFICATE_BASE64`
- `MACOS_CERTIFICATE_PASSWORD`

`.p12` や `.mobileprovision` は base64 化して登録する。

```sh
base64 -i release.keystore | pbcopy
base64 -i ios_distribution.p12 | pbcopy
base64 -i profile.mobileprovision | pbcopy
```

## 関連リポジトリ

- [MimicX-protocol](https://github.com/kunichiko/MimicX-protocol) - MIDI通信プロトコルライブラリ
- [MimicX-firmware](https://github.com/kunichiko/MimicX-firmware) - マイコンファームウェア
- [MimicX-hardware](https://github.com/kunichiko/MimicX-hardware) - 基板設計データ
