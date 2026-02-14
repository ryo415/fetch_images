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

依存関係をインストールします。

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
- `--fantia-email EMAIL`: Fantia ログイン用メールアドレス
- `--fantia-password PASSWORD`: Fantia ログイン用パスワード
- `--fanbox-session TOKEN`: FANBOX の `FANBOXSESSID`
- `--overwrite`: 既存ファイルを上書き
- `--dry-run`: ダウンロードせず対象ファイル数のみ確認
- `-h`, `--help`: ヘルプ表示

## 認証

公開投稿以外を取得する場合、セッション情報が必要です。

- Fantia
  - `--fantia-session` または `FANTIA_SESSION`
  - もしくは `--fantia-email` + `--fantia-password`（`FANTIA_EMAIL` / `FANTIA_PASSWORD` でも可）
- FANBOX
  - `--fanbox-session` または `FANBOX_SESSION`

ブラウザの開発者ツールから cookie 値を取得して設定してください。

## 実行例

```bash
bundle exec bin/fetch_images \
  --output downloads \
  --fantia-session "$FANTIA_SESSION" \
  --fanbox-session "$FANBOX_SESSION" \
  https://fantia.jp/posts/12345 \
  https://creator.fanbox.cc/posts/67890
```

`--dry-run` の例:

```bash
bundle exec bin/fetch_images --dry-run https://fantia.jp/posts/12345
```

## 出力ディレクトリ

投稿ごとに以下の形式でサブディレクトリが作成されます。

- Fantia: `fantia_<creator>_<post_id>_<title>`
- FANBOX: `fanbox_<creator>_<post_id>_<title>`

各画像は `001_...`, `002_...` のように連番付きファイル名で保存されます。

## 備考

- `fantia_fetcher.rb` は Fantia 専用の旧スクリプトです。
- 現在の推奨エントリポイントは `bin/fetch_images` です。
