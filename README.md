# fetch_images

A lightweight Ruby command line utility for downloading images from Fantia and Pixiv Fanbox posts.

## Installation

The tool only depends on Ruby's standard library. Clone this repository and make the executable available:

```bash
bundle install # optional, no dependencies required
chmod +x bin/fetch_images
```

## Usage

```
bin/fetch_images [options] <POST_URL> [<POST_URL> ...]
```

Downloaded files are stored under the `downloads/` directory by default. Use `--output` to change the destination.

### Authentication

Private or paid posts on both platforms require valid session cookies.

- **Fantia** – provide your `_session_id` value using `--fantia-session` or by setting the `FANTIA_SESSION` environment variable.
- **Fanbox** – provide your `FANBOXSESSID` value using `--fanbox-session` or by setting the `FANBOX_SESSION` environment variable.

### Additional options

- `--overwrite`: replace existing files when re-running the command.
- `--dry-run`: show the files that would be downloaded without saving them.

## Example

```bash
bin/fetch_images https://fantia.jp/posts/12345 \
  https://creator.fanbox.cc/posts/67890 \
  --output my_downloads --fanbox-session <FANBOXSESSID>
```
