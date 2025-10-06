# fetch_images

A lightweight Ruby command line utility for downloading images from Fantia and Pixiv Fanbox posts.

## Installation

Install the required gem bundle locally under `vendor/bundle` and make the executable available:

```bash
bundle install --path vendor/bundle
chmod +x bin/fetch_images
```

Bundler still writes the environment under `vendor/bundle` even though the CLI has no external gem dependencies. If your Ruby distribution includes the optional `unicode_normalize` default gem it will be used for cleaner post directory names, but the tool gracefully falls back when it is unavailable.

## Usage

Run the CLI through Bundler so it automatically loads the vendored dependencies:

```bash
bundle exec bin/fetch_images [options] <POST_URL> [<POST_URL> ...]
```

Downloaded files are stored under the `downloads/` directory by default. Use `--output` to change the destination.

### Authentication

Private or paid posts on both platforms require valid session cookies.

- **Fantia** – provide your `_session_id` value using `--fantia-session` or by setting the `FANTIA_SESSION` environment variable.
- **Fanbox** – provide your `FANBOXSESSID` value using `--fanbox-session` or by setting the `FANBOX_SESSION` environment variable.

#### Getting the session cookies

1. Log into the platform in a desktop browser.
2. Open the developer tools and look for the storage/cookies panel (`Application` in Chrome, `Storage` in Firefox).
3. Select the relevant domain and copy the cookie value:
   - Fantia: `_session_id` on `fantia.jp`
   - Fanbox: `FANBOXSESSID` on `fanbox.cc`
4. Pass the copied value to the CLI option or set it via the matching environment variable.

#### Logging into Fantia with credentials

As an alternative to copying cookies manually, the CLI can authenticate against Fantia when supplied with your email address and password:

```bash
bundle exec bin/fetch_images --fantia-email you@example.com --fantia-password "your-password" \
  https://fantia.jp/posts/12345
```

The credentials are used to establish a temporary session and are not stored. For better security, you can also set `FANTIA_EMAIL` and `FANTIA_PASSWORD` environment variables instead of passing credentials directly on the command line. Fanbox still requires a `FANBOXSESSID` cookie because its login flow is tied to Pixiv's OAuth process.

### Additional options

- `--overwrite`: replace existing files when re-running the command.
- `--dry-run`: show the files that would be downloaded without saving them.

## Example

```bash
bundle exec bin/fetch_images https://fantia.jp/posts/12345 \
  https://creator.fanbox.cc/posts/67890 \
  --output my_downloads --fanbox-session <FANBOXSESSID>
```
