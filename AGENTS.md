# Repository Guidelines

## Start of Each Task

- Read `README.md` for the purpose, usage, current behavior, and limitations; then inspect the affected implementation and tests.
- Check `git status --short` and relevant diffs; preserve existing uncommitted work.
- Use current files as evidence rather than relying on previous conversations. Resolve discrepancies between documentation and implementation before changing behavior.
- Update README when CLI behavior changes; update this file when structure or development procedures change. Keep detailed user-facing specifications in README instead of duplicating them here.

## Project Structure & Module Organization

- `bin/fetch_images`: primary CLI entrypoint.
- `lib/fetch_images/`: core library code.
  - `cli.rb`: CLI option parsing and client orchestration.
  - `option_resolver.rb`: saved/environment/explicit option resolution and credential source precedence.
  - `download_runner.rb`: shared download execution, client/logger lifecycle, and result validation.
  - `reporter.rb`: result messages and normal/queue output prefixes.
  - `settings.rb`: user settings JSON validation and persistence.
  - `settings_command.rb`: `auth` / `config` command handling.
  - `download_queue.rb`: mixed-site URL input, FIFO processing, and status display.
  - `client.rb`: shared HTTP/download behavior.
  - `logger.rb`, `support.rb`: shared logging and utility helpers.
  - `clients/fantia.rb`, `clients/fanbox.rb`, `clients/myfans.rb`: platform-specific implementations.
  - `errors.rb`, `download_result.rb`, `version.rb`: shared models and constants.
- `lib/fantia/` and `fantia_fetcher.rb`: legacy Fantia-only flow (kept for backward compatibility).
- `scripts/`: Playwright helper scripts used as browser-based fallbacks for FANBOX/MyFans extraction.
- `package.json`: Node/Playwright dependency manifest for the helper scripts.
- `test/test_workflow.rb`: Minitest coverage for settings, credential precedence, and queue behavior.
- `downloads/`: default output directory for downloaded files.
- Bundler's local install path is configurable. Older documentation used `vender/bundle`; the current local configuration uses `vendor/bundle`. Check `bundle config get path` rather than assuming either or changing existing settings.

## Build, Test, and Development Commands

- `bundle install`: install Ruby dependencies using existing Bundler configuration.
- `npm install` and `npx playwright install chromium`: install Playwright and the selected browser when working on browser fallback scripts.
- `bundle exec ruby test/test_workflow.rb`: run the offline workflow tests.
- `bundle exec bin/fetch_images --help`: verify CLI boots and list options.
- `bundle exec bin/fetch_images <fantia|fanbox> --dry-run <POST_URL>`: verify extraction with suitable authentication. The service subcommand is required; dry-run still fetches post data and creates the output root.
- `ruby -c bin/fetch_images` and `ruby -c lib/fetch_images/clients/fantia.rb`: quick syntax checks.
- Run `ruby -c` on changed Ruby files, `node --check` on changed helper scripts, and `git diff --check` on the diff.

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

- Run `bundle exec ruby test/test_workflow.rb` for changes to settings or queue behavior. Tests use temporary directories, dummy Cookies, and manual FANBOX JSON without contacting real sites.
- These tests do not verify current site HTML/API behavior or live downloads.
- Before opening a PR, run:
  - syntax checks (`ruby -c ...`)
  - at least one `--dry-run` against a Fantia or FANBOX URL
  - one real download test when credentials are available.
- If you add tests, prefer Minitest under `test/` with names like `test_<feature>.rb`.
- Report when live verification was not performed. A dummy `--fanbox-post-info-json` payload can be used for an offline dry-run; do not describe this as live site verification.

## Behavior to Preserve

- The usual workflow is `auth <site>` to register Cookie, `config <site>` to save preferences, and `queue` to submit URLs. Existing service-specific commands also use saved settings.
- Precedence is explicit options > environment variables > saved settings > defaults. Authentication is selected as a group from the highest-priority source rather than mixing lower-priority credentials.
- Queue accepts input during a download but processes one URL at a time. `:quit` / EOF drains submitted jobs; the queue is not persisted between runs.
- Queue treats zero results and partial downloads as failures. Ordinary service commands have different failure semantics; see README before changing either.
- Keep the legacy Fantia flow independent unless the task explicitly affects it.

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
- `auth` also accepts Cookie through hidden terminal input. User settings contain plaintext Cookie and live outside the repository at `$XDG_CONFIG_HOME/fetch_images/config.json`, defaulting to `~/.config/fetch_images/config.json`; preserve directory mode 0700 and file mode 0600 when saving.
- Do not display actual user settings, logs, or authenticated captures just to understand the project. `config <site>` displays preferences without Cookie values.
- Treat Playwright helper outputs and captured JSON/HTML as sensitive if they may contain authenticated post data.
