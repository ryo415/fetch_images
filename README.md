# fetch_images

Fantia / Pixiv FANBOX / MyFans の投稿から画像・動画を一括ダウンロードする Ruby CLI です。

## 対応URL

- Fantia: `https://fantia.jp/posts/<id>`
- Fantia（fanclub配下）: `https://fantia.jp/fanclubs/<fanclub_id>/posts/<id>`
- FANBOX: `https://<creator>.fanbox.cc/posts/<id>`
- FANBOX: `https://www.fanbox.cc/@<creator>/posts/<id>`
- MyFans: `https://myfans.jp/...`（投稿ページURL）
  - 投稿詳細ページURLを指定してください（トップ/一覧/プロフィールURLは非推奨）
  - 例: `https://myfans.jp/posts/<id>` または `https://myfans.jp/<creator>/posts/<id>`

## 動作環境

- Ruby 3.x
- Bundler
- ffmpeg（MyFans の HLS 動画を mp4 保存する場合）

```bash
bundle install --path vender/bundle
```

## 使い方

```bash
bundle exec bin/fetch_images <subcommand> [options] <POST_URL> [<POST_URL> ...]
```

デフォルトの保存先は `downloads/` です。

利用できるサブコマンド:

- `fantia`
- `fanbox`
- `myfans`

サブコマンドは必須です。指定したサブコマンドと URL のサービスが一致しない場合はエラーになります。

### 共通オプション

- `-o`, `--output DIR`: 出力先ディレクトリ（デフォルト: `./downloads`）
- `--overwrite`: 既存ファイルを上書き
- `--dry-run`: ダウンロードせず対象件数のみ表示
- `-v`, `--verbose`: デバッグログを標準エラーへ出力
- `--log-file PATH`: ログをファイル出力（省略時 `./fetch_images.log`）
- `-h`, `--help`: ヘルプ表示

### サブコマンド別オプション

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
- `--fanbox-playwright`: FANBOX API が 403 のとき Playwright フォールバックを有効化
- `--fanbox-playwright-browser NAME`: `chromium|firefox|webkit`（デフォルト: `chromium`）
- 必須条件: `--fanbox-session` または `--fanbox-cookie`、もしくは `--fanbox-post-info-json`

`myfans`:

- `--myfans-session TOKEN`: MyFans のセッションCookie値
- `--myfans-cookie HEADER`: MyFans の Cookie ヘッダー全文
- `--myfans-playwright`: MyFans の動画抽出で Playwright フォールバックを有効化
- `--myfans-playwright-browser NAME`: `chromium|firefox|webkit`（デフォルト: `chromium`）
- 必須条件: `--myfans-session` または `--myfans-cookie`

## 認証

公開範囲外の投稿取得にはセッション情報が必要です。

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

## Usage

全体ヘルプ:

```bash
bundle exec bin/fetch_images --help
```

サブコマンド別ヘルプ:

```bash
bundle exec bin/fetch_images fantia --help
bundle exec bin/fetch_images fanbox --help
bundle exec bin/fetch_images myfans --help
```

MyFans（URL指定の注意）:

```text
OK:   投稿詳細ページURL（1投稿を表示するページ）
NG:   トップページ / 投稿一覧 / プロフィールページ
```

## 出力仕様（Fantia）

- 同一画像の `main/large/medium/small/micro/thumb` 派生は代表1枚に整理して保存します。
- `thumb`, `thumb_webp`, `micro`, `small`, `ogp` は最終出力から除外します。
- 拡張子なしURLは `Content-Type` から拡張子を補完して保存します（例: `.jpg`）。

## 出力仕様（MyFans）

- 動画URLが取得できた場合は動画を優先して保存し、動画が見つからない場合は画像を保存します。
- HLS（`.m3u8`）は `ffmpeg` を使って `mp4` に変換して保存します。
- HLS変換に失敗したURLはスキップし、`--verbose` または `--log-file` のログに理由を出力します。

## 備考

- `fantia_fetcher.rb` は Fantia 専用の旧スクリプトです。
- 現在の推奨エントリポイントは `bin/fetch_images` です。
