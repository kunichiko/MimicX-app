# iOS CI 署名運用メモ

GitHub Actions の Release Build ワークフロー (`.github/workflows/release-build.yml`)
で iOS をビルドする際の署名設定と、**1 年に 1 回必要な証明書 / プロビジョニング
プロファイル更新作業** をまとめる。

## 現在の構成 (v1.3.3 以降)

iOS ビルドは 2 種類の Apple 証明書を使い分けている:

| 用途 | 証明書 | プロファイル | 由来 |
|---|---|---|---|
| **Archive (Runner.app の Release ビルド)** | Apple Development | iOS App Development | 事前作成 (P12 を Secret に登録) |
| **Export (配布用 IPA への再署名)** | Apple Distribution | App Store / Ad Hoc | 事前作成 (P12 を Secret に登録) |

Archive 段階は SPM プラグインのリソースバンドル問題のため **Automatic signing**
で動かしているが、keychain に Apple Development 証明書を **プリインストール** して
おくことで Xcode が Apple Developer Portal に新規発行を依頼しなくなる。これに
より「`Created via API` 証明書が無限に増殖して発行枠を圧迫」する問題を回避。

詳細経緯は `.github/workflows/release-build.yml` 内コメントと commit
`89be1f9` (ci(ios): preinstall iOS Development cert/profile to avoid cert quota
exhaustion) を参照。

## GitHub Secrets 一覧

### Archive 用 (Apple Development)

| Secret 名 | 中身 |
|---|---|
| `IOS_DEVELOPMENT_CERTIFICATE_BASE64` | Apple Development の P12 を base64 化したもの |
| `IOS_DEVELOPMENT_CERTIFICATE_PASSWORD` | 上記 P12 のパスワード |
| `IOS_DEVELOPMENT_PROFILE_BASE64` | Development プロビジョニングプロファイルを base64 化したもの |

### Export 用 (Apple Distribution)

| Secret 名 | 中身 |
|---|---|
| `IOS_CERTIFICATE_BASE64` | Apple Distribution の P12 を base64 化したもの |
| `IOS_CERTIFICATE_PASSWORD` | 上記 P12 のパスワード |
| `IOS_APP_STORE_PROVISIONING_PROFILE_BASE64` | App Store Connect 用プロファイルの base64 |
| `IOS_PROVISIONING_PROFILE_BASE64` | Ad Hoc 用プロファイルの base64 |

### その他 (枠の管理用)

| Secret 名 | 中身 |
|---|---|
| `APPLE_TEAM_ID` | 10 文字の Team ID |
| `KEYCHAIN_PASSWORD` | CI runner 上の一時 keychain パスワード (任意の強力な文字列) |
| `APPSTORE_ISSUER_ID` | App Store Connect API Issuer ID |
| `APPSTORE_KEY_ID` | API Key ID |
| `APPSTORE_PRIVATE_KEY` | API Key (.p8) の中身か、その base64 |
| `BUNDLE_ID` | アプリ Bundle ID (`jp.ohnaka.MimicX`) |

## 期限

Apple の運用上:

- **証明書 (Apple Development / Apple Distribution)** : **1 年で期限切れ**
- **プロビジョニングプロファイル** : 通常 **1 年で期限切れ** (証明書側に合わせる)
- **App Store Connect API キー** : 無期限 (revoke 操作するまで有効)

つまり **Apple Development / Distribution は年に 1 回更新が必要**。期限切れに近づくと CI ビルドが失敗するようになるので、Apple Developer Portal の Certificates ページで有効期限を時々確認しておく。

---

## 年次更新作業手順

### 0. 事前確認

- macOS ローカル環境
- Xcode インストール済み (`Xcode > Settings > Accounts` で Apple ID にサインインしておく)
- リポジトリの管理者権限 (GitHub Secrets の更新権限)

### 1. CSR (Certificate Signing Request) を作る

Apple Development と Apple Distribution それぞれの cert に同じ CSR は使えるので、ここでは 1 つ作って両方に使う。

1. **Keychain Access.app** を起動
2. メニュー「キーチェーンアクセス」→「証明書アシスタント」→「**認証局に証明書を要求**」
3. ダイアログで:
   - メールアドレス: 担当者の Apple ID
   - 通称: なんでも可 (例: `MimicX CI 2027`)
   - 「**ディスクに保存**」を選択 + 「**鍵ペア情報を指定**」にチェック
4. 任意の場所に `.certSigningRequest` ファイルを保存
5. 続いて鍵ペア設定 (RSA / 2048 ビット / 既定でOK)

→ ファイルと、Keychain Access の「鍵」カテゴリに公開鍵 + 秘密鍵がペアで出来る。

### 2. Apple Development 証明書を再発行

1. https://developer.apple.com/account/resources/certificates/list を開く
2. 期限切れになる古い Apple Development 証明書を **revoke** (一覧から選択 → Revoke)
3. **+** ボタン → 「Apple Development」を選択 → Continue
4. ステップ 1 で作った `.certSigningRequest` をアップロード → Continue
5. ダウンロードして `.cer` を取得
6. `.cer` をダブルクリック → Keychain に取り込み

### 3. Apple Distribution 証明書を再発行

1. 同じ Certificates ページで期限切れになる古い Apple Distribution を revoke
2. **+** → 「Apple Distribution」を選択 → Continue
3. **同じ** `.certSigningRequest` をアップロード → Continue
4. `.cer` をダウンロード → ダブルクリックで Keychain 取り込み

### 4. プロビジョニングプロファイルを再発行

期限切れの Development / App Store / Ad Hoc 各プロファイルを再作成または期限延長する。

1. https://developer.apple.com/account/resources/profiles/list を開く
2. 各プロファイルを開き、新しい証明書 (ステップ 2 / 3) を選び直して **Generate** で発行し直す (古いほうは revoke)
3. 必要なのは下記 3 つ:
   - **iOS App Development** プロファイル (jp.ohnaka.MimicX)
   - **App Store Connect** プロファイル (jp.ohnaka.MimicX)
   - **Ad Hoc** プロファイル (jp.ohnaka.MimicX) ※ workflow_dispatch で `ios_distribution=ad-hoc` を選んだ時に使用
4. それぞれダウンロードして `.mobileprovision` ファイルを保存

### 5. P12 エクスポート

Keychain Access で:

1. ステップ 2 で取り込んだ「**Apple Development: (氏名) (チームID)**」を選択
2. 三角を開いて秘密鍵がペアになっているか確認 (秘密鍵の行が下にぶら下がっている)
3. 証明書 **と** 秘密鍵の両方を **Cmd+クリックで複数選択**
4. 右クリック → 「**2 個の項目を書き出す**」
5. フォーマット: **Personal Information Exchange (.p12)**
6. 保存名 (例: `mimicx-ios-dev-2027.p12`)
7. **強力なパスワード** を設定 (このあと Secret に入れる)

Apple Distribution についても同じ手順で P12 を作る (例: `mimicx-ios-dist-2027.p12`)。

### 6. base64 化

```sh
cd <P12 と mobileprovision を置いた場所>

# Development 系
base64 -i mimicx-ios-dev-2027.p12 | pbcopy   # → Secret IOS_DEVELOPMENT_CERTIFICATE_BASE64
base64 -i MimicX_CI_Development.mobileprovision | pbcopy   # → Secret IOS_DEVELOPMENT_PROFILE_BASE64

# Distribution 系
base64 -i mimicx-ios-dist-2027.p12 | pbcopy   # → Secret IOS_CERTIFICATE_BASE64
base64 -i AppStore_MimicX.mobileprovision | pbcopy   # → Secret IOS_APP_STORE_PROVISIONING_PROFILE_BASE64
base64 -i AdHoc_MimicX.mobileprovision | pbcopy   # → Secret IOS_PROVISIONING_PROFILE_BASE64
```

`pbcopy` でクリップボードにコピーされるので、すぐ Secret に貼れる。

### 7. GitHub Secrets を更新

リポジトリ Settings → Secrets and variables → Actions

該当する Secret を選んで **Update** で上書き:

- `IOS_DEVELOPMENT_CERTIFICATE_BASE64`
- `IOS_DEVELOPMENT_CERTIFICATE_PASSWORD`
- `IOS_DEVELOPMENT_PROFILE_BASE64`
- `IOS_CERTIFICATE_BASE64`
- `IOS_CERTIFICATE_PASSWORD`
- `IOS_APP_STORE_PROVISIONING_PROFILE_BASE64`
- `IOS_PROVISIONING_PROFILE_BASE64`

パスワードを変えていなければ `*_PASSWORD` は据え置きでもOK。

### 8. 動作確認

タグを切らずに workflow_dispatch で iOS のみテストビルド:

```sh
gh workflow run "Release Build" \
  --ref main \
  -f platform=ios \
  -f ios_distribution=ad-hoc \
  -f upload_testflight=false
```

`Install iOS signing assets` ステップのログで以下が出れば preinstall モードが
効いている (= Apple に新規発行依頼が走っていない):

```
Installing Apple Development certificate + profile (preinstalled mode)
Development profile UUID: ...
```

`Archive iOS app` ステップが ARCHIVE SUCCEEDED で終わればOK。

### 9. 古い証明書を整理

完全に置き換わったら、Apple Developer Portal の Certificates ページで古い
証明書 (revoke 済みになっているはず) を削除しておくと一覧がスッキリする。

---

## トラブルシューティング

### `Choose a certificate to revoke. Your account has reached the maximum number of certificates.`

Apple Development の発行枠 (Personal Team は 2 枚 / Organization は 3 枚) を
超えた。

- 通常は preinstall モードが効いていれば発生しないはず
- 出ているということは:
  - GitHub Secret の `IOS_DEVELOPMENT_*` が未設定 / 空 / 壊れている
  - Workflow が古い (cert install ステップが入っていない)
- 対処:
  1. Portal で `Created via API` の古い証明書を revoke
  2. Secret 3 つが正しく設定されているか再確認

### `error: No profiles for 'jp.ohnaka.MimicX' were found`

プロビジョニングプロファイルが期限切れ or App ID とミスマッチ。

- Portal でプロファイル一覧を確認 → 期限切れなら更新 (ステップ 4)
- App ID 側の Capabilities が変わっていないか確認 (Push Notifications を新規に
  オンにした等、Capability を変えたらプロファイルは作り直しが必要)

### Archive は通るが Export で失敗する

Distribution 証明書 / プロファイルの期限切れか、ExportOptions.plist の
`signingCertificate` 値とのミスマッチ。

- `release-build.yml` の `Generate ExportOptions.plist` ステップで指定している
  `<string>Apple Distribution</string>` という値は **証明書の名前ではなく Apple
  の固定 enum** なので、これは通常触らない
- 失敗ログに「No signing certificate ... found」と出るときは Distribution P12 が
  期限切れ → ステップ 3 と 5 と 7 を再実行
