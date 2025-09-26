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
- `-v`, `--[no-]verbose` – Enable verbose logging to see progress messages.

If you provide both an email and password (or supply a password via stdin/prompt), the script performs the Fantia sign-in flow automatically before downloading images. This avoids the need to copy cookies manually.

### Example

```
bundle exec ruby fantia_fetcher.rb -o downloads -v --email you@example.com --password-prompt https://fantia.jp/posts/123456
```

This command prompts for your Fantia password, logs in with the supplied email, and downloads all images referenced by the article into the `downloads` directory while showing progress logs.
