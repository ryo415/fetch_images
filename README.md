# fetch_images

A simple Ruby script for downloading all images from a Fantia article.

## Requirements

- Ruby 3.0 or later
- Bundler (`gem install bundler` if it is not already available)
- The [`nokogiri`](https://nokogiri.org/) gem is installed through Bundler

Install the dependencies with Bundler so they are stored under `vender/bundle`:

```
bundle install --path vender/bundle
```

## Usage

Run the script via Bundler to ensure the dependencies are available:

```
bundle exec ruby fantia_fetcher.rb [options] ARTICLE_URL
```

### Options

- `-o`, `--output DIR` – Directory to save the downloaded images (default: `images`).
- `-c`, `--cookie COOKIE` – Optional `Cookie` header for requests when you already have a valid Fantia session.
- `-u`, `--email EMAIL` – Fantia account email for logging in.
- `-p`, `--password PASSWORD` – Fantia account password (plain text; consider the options below instead).
- `--password-stdin` – Read the Fantia password from standard input (e.g., `echo 'pass' | ...`).
- `--password-prompt` – Prompt for the Fantia password with input hidden.
- `--otp CODE` – Supply a Fantia two-factor authentication (2FA) one-time password directly.
- `--otp-stdin` – Read the Fantia 2FA code from standard input when Fantia asks for it.
- `--otp-prompt` – Prompt for the Fantia 2FA code with input hidden when the challenge appears.
- `-v`, `--[no-]verbose` – Enable verbose logging to see progress messages.

If you provide both an email and password (or supply a password via stdin/prompt), the script performs the Fantia sign-in flow automatically before downloading images. The authenticator verifies the session by loading your Fantia mypage so member-only content can be fetched reliably. Fantia sends two-factor authentication codes by email after the initial login attempt. When the script detects this challenge it will, by default, prompt for the code in interactive terminals so you can paste it once it arrives. In non-interactive scenarios, supply the OTP using one of the options above once you receive the email. The downloader also sends the article URL as the HTTP `Referer` header for each image request to match Fantia's access checks.

### Example

```
bundle exec ruby fantia_fetcher.rb -o downloads -v --email you@example.com --password-prompt --otp-prompt https://fantia.jp/posts/123456
```

This command prompts for your Fantia password and, when Fantia emails a one-time password, requests the code before downloading all images referenced by the article into the `downloads` directory while showing progress logs.
A lightweight Ruby command line utility for downloading images from Fantia and Pixiv Fanbox posts.

## Installation

Install the required gem bundle locally under `vender/bundle` and make the executable available:

```bash
bundle install --path vender/bundle
chmod +x bin/fetch_images
```

Bundler still writes the environment under `vender/bundle` even though the CLI has no external gem dependencies. If your Ruby distribution includes the optional `unicode_normalize` default gem it will be used for cleaner post directory names, but the tool gracefully falls back when it is unavailable.

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
