# fetch_images

Fantia / Pixiv FANBOX の投稿から画像を一括ダウンロードする Ruby CLI です。

## 対応URL

- Fantia: `https://fantia.jp/posts/<id>`
- Fantia（fanclub配下）: `https://fantia.jp/fanclubs/<fanclub_id>/posts/<id>`
- FANBOX: `https://<creator>.fanbox.cc/posts/<id>`
- FANBOX: `https://www.fanbox.cc/@<creator>/posts/<id>`

## 動作環境

- Ruby 3.x
- Bundler

```bash
bundle install --path vender/bundle
```

## 使い方

```bash
bundle exec bin/fetch_images [options] <POST_URL> [<POST_URL> ...]
```

デフォルトの保存先は `downloads/` です。

### オプション

- `-o`, `--output DIR`: 出力先ディレクトリ（デフォルト: `./downloads`）
- `--fantia-session TOKEN`: Fantia の `_session_id`
- `--fantia-cookie HEADER`: Fantia の Cookie ヘッダー全文
- `--fantia-email EMAIL`: Fantia ログイン用メールアドレス
- `--fantia-password PASSWORD`: Fantia ログイン用パスワード
- `--fanbox-session TOKEN`: FANBOX の `FANBOXSESSID`
- `--overwrite`: 既存ファイルを上書き
- `--dry-run`: ダウンロードせず対象件数のみ表示
- `-v`, `--verbose`: デバッグログを標準エラーへ出力
- `--log-file PATH`: ログをファイル出力（省略時 `./fetch_images.log`）
- `-h`, `--help`: ヘルプ表示

## 認証

公開範囲外の投稿取得にはセッション情報が必要です。

- Fantia
  - 推奨: `--fantia-cookie` または `FANTIA_COOKIE`
  - 代替: `--fantia-session` または `FANTIA_SESSION`
  - 代替: `--fantia-email` + `--fantia-password`（`FANTIA_EMAIL` / `FANTIA_PASSWORD`）
- FANBOX
  - `--fanbox-session` または `FANBOX_SESSION`

## 実行例

Fantia（Cookie ヘッダー指定）:

```bash
bundle exec bin/fetch_images \
  --fantia-cookie 'cookieヘッダー全文' \
  --output downloads_fantia \
  https://fantia.jp/posts/xxxxxx
```

デバッグログ付き:

```bash
bundle exec bin/fetch_images \
  --fantia-cookie 'cookieヘッダー全文' \
  --verbose \
  --log-file fantia_debug.log \
  https://fantia.jp/posts/xxxxxxx
```

## 出力仕様（Fantia）

- 同一画像の `main/large/medium/small/micro/thumb` 派生は代表1枚に整理して保存します。
- `thumb`, `thumb_webp`, `micro`, `small`, `ogp` は最終出力から除外します。
- 拡張子なしURLは `Content-Type` から拡張子を補完して保存します（例: `.jpg`）。

## 備考

- `fantia_fetcher.rb` は Fantia 専用の旧スクリプトです。
- 現在の推奨エントリポイントは `bin/fetch_images` です。
