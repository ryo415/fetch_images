# fetch_images

Fantia / Pixiv FANBOX / MyFans の投稿から画像・動画を一括ダウンロードする Ruby CLI です。
Fantia・FANBOXは画像、MyFansは動画を優先し、動画がなければ画像を取得します。
投稿URLを指定して利用します。作者の全投稿を自動巡回する機能はありません。

普段の操作は **`auth` でCookie登録 → `config` で設定保存 → `queue` にURLを投入** です。
開発時のルール・読むべきファイル・検証手順は [AGENTS.md](AGENTS.md) を参照してください。

## 対応URL

- Fantia: `https://fantia.jp/posts/<id>`
- Fantia（fanclub配下）: `https://fantia.jp/fanclubs/<fanclub_id>/posts/<id>`
- FANBOX: `https://<creator>.fanbox.cc/posts/<id>`
- FANBOX: `https://www.fanbox.cc/@<creator>/posts/<id>`
- MyFans: `https://myfans.jp/...`（投稿ページURL）
  - 投稿詳細ページURLを指定してください（トップ/一覧/プロフィールURLは非推奨）
  - 例: `https://myfans.jp/posts/<id>` または `https://myfans.jp/<creator>/posts/<id>`

## 動作環境

- Ruby 3.2以降（現在のロック済み依存関係の要件。開発時の動作確認はRuby 4.0.6）
- Bundler
- Node.js（Playwright利用時。`mise.toml` はNode 24を指定）
- ffmpeg（MyFans の HLS 動画を mp4 保存する場合）

```bash
bundle install
```

インストール先は `bundle config get path` で確認できます。旧設定は `vender/bundle`、
現在のローカル設定は `vendor/bundle` です。新規環境でローカル保存先を指定する場合は
`bundle config set --local path vendor/bundle` を実行してからインストールしてください。

## 使い方

```bash
bundle exec bin/fetch_images <subcommand> [options] <POST_URL> [<POST_URL> ...]
```

デフォルトの保存先は `downloads/` です。

| サブコマンド | 用途 |
| --- | --- |
| `auth <site>` | Cookieの登録・更新・削除 |
| `config <site>` | 保存先・Playwright設定の保存と確認 |
| `queue` | 標準入力からサイト混在の投稿URLを受付 |
| `fantia` / `fanbox` / `myfans` | 指定サイトの投稿URLを1件以上処理 |

`<site>` は `fantia` / `fanbox` / `myfans` です。
サイト別コマンドはサブコマンドとURLのサービスが一致しない場合にエラーになります。

### Cookieを保存してURLを続けて投入する

初回とCookieの有効期限が切れたときに、利用するサイトのCookieヘッダー全文を登録します。
コマンド実行後の入力欄に貼り付けてEnterを押してください。端末上では入力を表示しません。
`Cookie:` 接頭辞が付いたままでも登録できます。登録時には通信・ログイン確認を行いません。

```bash
bundle exec bin/fetch_images auth myfans
bundle exec bin/fetch_images auth fanbox
bundle exec bin/fetch_images auth fantia
```

普段使う保存先やPlaywrightの設定もサイト別に保存できます。
保存先は登録時に絶対パスに変換されます。Playwright利用時は別途 `npm install` と
`npx playwright install chromium`（別ブラウザならその名前）が必要です。

```bash
bundle exec bin/fetch_images config myfans --output ./downloads_myfans --playwright --browser chromium
bundle exec bin/fetch_images config fanbox --output ./downloads_fanbox --playwright
bundle exec bin/fetch_images config fantia --output ./downloads_fantia
```

普段は次のコマンドを一度起動し、投稿URLを1行ずつ貼り付けてEnterを押すだけです。

```bash
bundle exec bin/fetch_images queue
```

- サイトをURLから自動判別します。Fantia・FANBOX・MyFansを混在させられます。
- 複数行のまとめ貼りに対応し、ダウンロード中も次のURLを受け付けます。取得は投入順に1件ずつ行います。
- ログは `[QUEUE]`（受付）、`[START]`（開始）、`[RESULT]`（取得件数）、`[DONE]`（完了）、`[FAIL]`（失敗）を行頭に付け、入力したURLと区別します。
- MyFansは `/posts/<id>` または `/<creator>/posts/<id>` 形式を受け付けます。
- `:quit` またはCtrl+Dで受付を終了し、投入済みURLの処理が終わるまで待ちます。
- Ctrl+Cは中断です。キューはメモリ上のみで、次回起動時には復元されません。
- 失敗しても次へ進み、終了時に失敗URLを再表示します。再投入で再試行でき、既存ファイルは通常スキップされます。
- キューでは取得対象0件・一部取得失敗も失敗として扱います。これはCookie切れとは限らず、閲覧権限や抽出処理も確認してください。
- 未対応URLや取得失敗があれば終了コード1、中断は130です。
- 各URLの処理開始時に設定を読み直すため、別の端末でCookieを更新できます。

入力と状態表示の例：

```text
https://myfans.jp/posts/123
[QUEUE]  https://myfans.jp/posts/123
[START]  https://myfans.jp/posts/123
[RESULT] Downloaded 1 file(s) from https://myfans.jp/posts/123
[DONE]   https://myfans.jp/posts/123
```

エラー詳細は `[ERROR]`、失敗URLの再表示は `[RETRY]`、案内は `[INFO]` です。
URL受付とダウンロードは並行するため、別のURLの状態表示が間に入る場合があります。

ファイルからの投入や、全サイト共通の一時的なオプション指定にも対応します。

```bash
bundle exec bin/fetch_images queue < urls.txt
bundle exec bin/fetch_images queue --dry-run
bundle exec bin/fetch_images queue --output ./downloads --verbose
```

`queue` のURLは引数ではなく標準入力に渡します。受け付けるオプションは下記の共通オプションです。
サイト固有のオプションは保存済み設定か環境変数を使います。

### 設定の保存先と優先順位

保存した設定は従来の `fantia` / `fanbox` / `myfans` コマンドでも使われます。
優先順位は **明示オプション → 環境変数 → 保存済み設定 → 既定値** です。
認証方式を混ぜないよう、明示した認証オプションがあれば環境変数・保存済みの認証情報は使わず、
認証の環境変数があれば保存済みCookieは使いません。

```bash
bundle exec bin/fetch_images config myfans                  # Cookie値を表示せず設定確認
bundle exec bin/fetch_images config myfans --no-playwright  # フォールバックを無効化
bundle exec bin/fetch_images auth myfans --clear            # 保存済みCookieを削除
```

設定ファイルは `$XDG_CONFIG_HOME/fetch_images/config.json`、未指定なら
`~/.config/fetch_images/config.json` です。Cookieは暗号化せず保存し、ディレクトリを0700・
ファイルを0600に制限します。実際のCookieをリポジトリへコピーしないでください。

保存する項目はサイトごとの `cookie` / `output` / `playwright` / `browser` です。
FantiaにはPlaywright設定がありません。`auth --clear` はCookieだけを削除し、保存先などは保持します。
`config <site>` は保存済み設定の表示であり、環境変数を適用した最終設定の表示ではありません。

環境変数は次のものを利用できます（空値は無視します）。

| サイト・用途 | 環境変数 |
| --- | --- |
| Fantia認証 | `FANTIA_COOKIE`, `FANTIA_SESSION`, `FANTIA_EMAIL`, `FANTIA_PASSWORD` |
| FANBOX認証・手動JSON | `FANBOX_COOKIE`, `FANBOX_SESSION`, `FANBOX_POST_INFO_JSON` |
| FANBOXブラウザ | `FANBOX_PLAYWRIGHT_BROWSER` |
| MyFans認証 | `MYFANS_COOKIE`, `MYFANS_SESSION` |
| MyFansブラウザ | `MYFANS_PLAYWRIGHT_BROWSER` |
| MyFansの外部コマンド | `NODE_BIN`, `FFMPEG_BIN` |

ブラウザ名の指定だけではPlaywrightは有効になりません。`config --playwright` または
サイト別の `--fanbox-playwright` / `--myfans-playwright` も指定します。

### 共通オプション

- `-o`, `--output DIR`: 出力先ディレクトリ（デフォルト: `./downloads`）
- `--overwrite`: 既存ファイルを上書き
- `--dry-run`: メディアを保存せず対象件数を表示。通常は投稿情報の通信と出力先ルートの作成を行う
- `-v`, `--verbose`: デバッグログを標準エラーとファイルへ出力
- `--log-file PATH`: デバッグログのファイルを指定。単独指定ではファイルのみ。`--verbose` のみなら `./fetch_images.log`。両方未指定ならデバッグログは出力しない
- `-h`, `--help`: ヘルプ表示

### サブコマンド別オプション

以下の認証条件は、保存済みCookieや環境変数でも満たせます。毎回オプションに指定する必要はありません。

`fantia`:

- `--fantia-session TOKEN`: Fantia の `_session_id`
- `--fantia-cookie HEADER`: Fantia の Cookie ヘッダー全文
- `--fantia-email EMAIL`: Fantia ログイン用メールアドレス
- `--fantia-password PASSWORD`: Fantia ログイン用パスワード
- 必須条件: `--fantia-cookie` または `--fantia-session`、もしくは `--fantia-email` と `--fantia-password` の両方

`fanbox`:

- `--fanbox-session TOKEN`: FANBOX の `FANBOXSESSID`
- `--fanbox-cookie HEADER`: FANBOX の Cookie ヘッダー全文
- `--fanbox-post-info-json PATH`: ブラウザで取得した `post.info` のJSONを直接使用
- `--[no-]fanbox-playwright`: FANBOX APIの特定エラー時のPlaywrightフォールバックを有効化／無効化（401・403・404・410・422・429が対象）
- `--fanbox-playwright-browser NAME`: `chromium|firefox|webkit`（デフォルト: `chromium`）
- 必須条件: `--fanbox-session` または `--fanbox-cookie`、もしくは `--fanbox-post-info-json`

`myfans`:

- `--myfans-session TOKEN`: MyFans のセッションCookie値
- `--myfans-cookie HEADER`: MyFans の Cookie ヘッダー全文
- `--[no-]myfans-playwright`: MyFans の動画抽出でPlaywrightフォールバックを有効化／無効化
- `--myfans-playwright-browser NAME`: `chromium|firefox|webkit`（デフォルト: `chromium`）
- 必須条件: `--myfans-session` または `--myfans-cookie`

## 認証

CLIは公開投稿を指定した場合も、上記の認証条件を要求します。
Cookieの登録は有効期限を延長しません。期限切れの場合はブラウザから取得し直して `auth <site>` で更新します。

- Fantia
  - 推奨: `--fantia-cookie` または `FANTIA_COOKIE`
  - 代替: `--fantia-session` または `FANTIA_SESSION`
  - 代替: `--fantia-email` + `--fantia-password`（`FANTIA_EMAIL` / `FANTIA_PASSWORD`）
- FANBOX
  - `--fanbox-session` または `FANBOX_SESSION`
  - API 403 が出る場合は `--fanbox-cookie` + `--fanbox-playwright` を推奨
- MyFans
  - 推奨: `--myfans-cookie` または `MYFANS_COOKIE`
  - 代替: `--myfans-session` または `MYFANS_SESSION`
  - 動画URLがHTMLに出ない場合は `--myfans-playwright` を併用
  - `.m3u8` を mp4 に変換するため `ffmpeg` が必要（`FFMPEG_BIN` で実行パス指定可）

## 実行例

通常は上記の `auth` を使ってください。以下のCookie・セッション値は説明用プレースホルダーです。
実値を引数に書くとシェル履歴に残るため、実運用では保存済みCookieや環境変数を利用してください。

Fantia（Cookie ヘッダー指定）:

```bash
bundle exec bin/fetch_images fantia \
  --fantia-cookie 'cookieヘッダー全文' \
  --output downloads_fantia \
  https://fantia.jp/posts/xxxxxx
```

デバッグログ付き:

```bash
bundle exec bin/fetch_images fantia \
  --fantia-cookie 'cookieヘッダー全文' \
  --verbose \
  --log-file fantia_debug.log \
  https://fantia.jp/posts/xxxxxxx
```

FANBOX（通常取得: セッション値のみ）:

```bash
bundle exec bin/fetch_images fanbox \
  --fanbox-session 'FANBOXSESSIDの値' \
  --output downloads_fanbox \
  "https://<creator>.fanbox.cc/posts/<id>"
```

FANBOX（403対策: Cookie + Playwright）:

```bash
bundle exec bin/fetch_images fanbox \
  --fanbox-cookie 'cookieヘッダー全文' \
  --fanbox-playwright \
  --fanbox-playwright-browser chromium \
  --verbose \
  --log-file fanbox_debug.log \
  "https://<creator>.fanbox.cc/posts/<id>"
```

FANBOX（`post.info` JSON を手動利用）:

```bash
bundle exec bin/fetch_images fanbox \
  --fanbox-post-info-json /path/to/post.info.json \
  --output downloads_fanbox \
  "https://<creator>.fanbox.cc/posts/<id>"
```

MyFans（Cookie ヘッダー指定）:

```bash
bundle exec bin/fetch_images myfans \
  --myfans-cookie 'cookieヘッダー全文' \
  --myfans-playwright \
  --myfans-playwright-browser chromium \
  --output downloads_myfans \
  "https://myfans.jp/..."
```

## ヘルプ

全体ヘルプ:

```bash
bundle exec bin/fetch_images --help
```

サブコマンド別ヘルプ:

```bash
bundle exec bin/fetch_images fantia --help
bundle exec bin/fetch_images fanbox --help
bundle exec bin/fetch_images myfans --help
bundle exec bin/fetch_images auth --help
bundle exec bin/fetch_images config --help
bundle exec bin/fetch_images queue --help
```

## 共通の保存仕様

- 出力先の下に、Fantia・FANBOXは投稿タイトル、MyFansはハッシュタグを除去した本文候補を使ってディレクトリを作ります。
- 日本語を保持しつつ、ディレクトリ名に使えない記号などを置換します。通常のディレクトリ名には投稿IDを付けないため、同名の投稿は同じディレクトリになる場合があります。
- ファイル名は `001_元の名前` の形式です。拡張子なしの場合は応答の `Content-Type` から補完します。
- 既存ファイルは通常スキップし、`--overwrite` で上書きします。取得URLの重複投入をキュー自体が排除する機能はありません。
- 通常のHTTPダウンロードは一時ファイルを経由して保存します。

## 出力仕様（Fantia）

- 同一画像の `main/large/medium/small/micro/thumb` 派生は代表1枚に整理して保存します。
- `thumb`, `thumb_webp`, `micro`, `small`, `ogp` は最終出力から除外します。
- 拡張子なしURLは `Content-Type` から拡張子を補完して保存します（例: `.jpg`）。

## 出力仕様（MyFans）

- 動画URLが取得できた場合は動画を優先して保存し、動画が見つからない場合は画像を保存します。
- HLS（`.m3u8`）は `ffmpeg` を使って `mp4` に変換して保存します。
- HLS変換を含め、個別のファイル取得に失敗したURLは処理を続行し、`--verbose` または `--log-file` のログに理由を出力します。

## 取得方式と失敗時の扱い

- Fantiaは投稿APIを優先し、特定のHTTPエラー時にHTML解析へ移ります。
- FANBOXは手動JSON指定を優先し、通常は投稿ページと `post.info` APIを取得します。APIの特定エラー時は、有効ならPlaywrightを試し、その後HTML解析へ移ります。本文の元画像・画像マップ等を対象とし、アイコンなどを除外します。
- MyFansはHTML・埋め込みJSON・スクリプトから抽出し、動画候補がなくPlaywrightが有効ならブラウザでの抽出も試します。

| 実行方法 | 成功・失敗の判定 |
| --- | --- |
| サイト別コマンド | URLごとのエラー後も次へ進み、捕捉したエラーがあれば終了コード1。対象0件は通常0。MyFansの個別取得失敗は内部で捕捉されるため、終了コード0の場合がある |
| `queue` | 対象0件・一部取得失敗も失敗と判定。失敗や未対応URLがあれば1、正常終了は0、Ctrl+C中断は130 |

0件や失敗は認証切れだけを意味しません。閲覧権限・投稿URL・サイト側の変更も確認してください。
FANBOXの手動JSONは指定URLの投稿IDとの照合を行わないため、対応する投稿のJSONを指定します。
デバッグログや一時ディレクトリのHTML/JSONには認証済み投稿情報や署名付きURLが含まれる場合があります。

## 備考

- `fantia_fetcher.rb` は Fantia 専用の旧スクリプトです。
- 現在の推奨エントリポイントは `bin/fetch_images` です。
- 旧実装はOTP入力などの独自機能を持ち、現行CLIとは同一仕様ではありません。

## テスト

```bash
bundle exec ruby test/test_workflow.rb
```

一時ディレクトリ・ダミーCookie・手動FANBOX JSONを使用し、実サービスへの通信なしで
設定の保存、優先順位、キューの受付・終了・失敗処理を確認します。
実サービスの現在のHTML/APIへの対応や実ダウンロードは、このテストでは検証しません。
