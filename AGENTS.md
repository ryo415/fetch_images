# Repository Guidelines

## Project Structure & Module Organization
- `bin/fetch_images`: primary CLI entrypoint.
- `lib/fetch_images/`: core library code.
  - `cli.rb`: CLI option parsing and client orchestration.
  - `client.rb`: shared HTTP/download behavior.
  - `logger.rb`, `support.rb`: shared logging and utility helpers.
  - `clients/fantia.rb`, `clients/fanbox.rb`, `clients/myfans.rb`: platform-specific implementations.
  - `errors.rb`, `download_result.rb`, `version.rb`: shared models and constants.
- `lib/fantia/` and `fantia_fetcher.rb`: legacy Fantia-only flow (kept for backward compatibility).
- `scripts/`: Playwright helper scripts used as browser-based fallbacks for FANBOX/MyFans extraction.
- `package.json`: Node/Playwright dependency manifest for the helper scripts.
- `downloads/`: default output directory for downloaded files.
- `vender/bundle/`: local Bundler install path used by this project (note the directory name is `vender`).

## Build, Test, and Development Commands
- `bundle install --path vender/bundle`: install gem dependencies locally.
- `npm install`: install Playwright when working on browser fallback scripts.
- `bundle exec bin/fetch_images --help`: verify CLI boots and list options.
- `bundle exec bin/fetch_images --dry-run <POST_URL>`: validate URL handling without writing files.
- `ruby -c bin/fetch_images` and `ruby -c lib/fetch_images/clients/fantia.rb`: quick syntax checks.

## Coding Style & Naming Conventions
- Ruby style with `# frozen_string_literal: true` at file top.
- Indentation: 2 spaces, no tabs.
- Naming:
  - Classes/modules: `CamelCase` (e.g., `FetchImages::Clients::Fanbox`).
  - Files: `snake_case.rb` matching class responsibility.
- Methods/variables: `snake_case`.
- Keep platform-specific logic inside `lib/fetch_images/clients/`; place shared logic in `Client`.
- Keep Playwright/browser automation logic inside `scripts/`; do not embed it directly into the Ruby clients.

## Testing Guidelines
- No automated test suite is currently committed.
- Before opening a PR, run:
  - syntax checks (`ruby -c ...`)
  - at least one `--dry-run` against a Fantia or FANBOX URL
  - one real download test when credentials are available.
- If you add tests, prefer Minitest under `test/` with names like `test_<feature>.rb`.

## Commit & Pull Request Guidelines
- Follow existing history style: short imperative subject lines, e.g., `Add Fantia login support`, `Fix README.md`.
- Keep commits focused (one logical change per commit).
- PRs should include:
  - purpose and scope
  - behavioral changes (CLI flags, auth, output paths)
  - manual verification steps and sample commands
  - linked issue (if any).

## Security & Configuration Tips
- Never commit real session cookies, email/password, or `.env` secrets.
- Prefer environment variables (`FANTIA_SESSION`, `FANBOX_SESSION`, etc.) over inline secrets in shell history.
- Treat Playwright helper outputs and captured JSON/HTML as sensitive if they may contain authenticated post data.
