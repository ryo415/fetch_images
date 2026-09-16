# frozen_string_literal: true

module FetchImages
  module SiteDefinitions
    COMMON_OPTION_DEFINITIONS = [
      {
        args: ["-o", "--output DIR", "Directory for downloaded files (default: ./downloads)"],
        handler: ->(cli, dir) { cli.set_option(:output, File.expand_path(dir)) }
      },
      {
        args: ["--overwrite", "Overwrite existing files"],
        handler: ->(cli, _) { cli.set_option(:overwrite, true) }
      },
      {
        args: ["--dry-run", "List files without downloading"],
        handler: ->(cli, _) { cli.set_option(:dry_run, true) }
      },
      {
        args: ["-v", "--verbose", "Enable debug logging"],
        handler: ->(cli, _) { cli.set_option(:verbose, true) }
      },
      {
        args: ["--log-file PATH", "Write logs to file (default: ./fetch_images.log when --verbose)"],
        handler: ->(cli, path) { cli.set_option(:log_file, path) }
      }
    ].freeze
    COMMANDS = {
      "fantia" => {
        label: "Fantia",
        description: "Download images from Fantia posts",
        client_class: Clients::Fantia,
        env_defaults: {
          fantia_session: "FANTIA_SESSION",
          fantia_cookie: "FANTIA_COOKIE",
          fantia_email: "FANTIA_EMAIL",
          fantia_password: "FANTIA_PASSWORD"
        },
        options_title: "Fantia options:",
        option_definitions: [
          {
            args: ["--fantia-session TOKEN", "Fantia _session_id cookie value"],
            handler: ->(cli, value) { cli.set_option(:fantia_session, value) }
          },
          {
            args: ["--fantia-cookie HEADER", "Full Fantia Cookie header value"],
            handler: ->(cli, value) { cli.set_option(:fantia_cookie, value) }
          },
          {
            args: ["--fantia-email EMAIL", "Fantia account email for login"],
            handler: ->(cli, value) { cli.set_option(:fantia_email, value) }
          },
          {
            args: ["--fantia-password PASSWORD", "Fantia account password for login"],
            handler: ->(cli, value) { cli.set_option(:fantia_password, value) }
          }
        ],
        client_builder: lambda { |cli, logger|
          Clients::Fantia.new(
            session_id: cli.option(:fantia_session),
            cookie_header: cli.option(:fantia_cookie),
            credentials: cli.class.build_credentials(cli.option(:fantia_email), cli.option(:fantia_password)),
            logger: logger
          )
        },
        validator: lambda do |cli|
          has_cookie = cli.option_present?(:fantia_cookie)
          has_session = cli.option_present?(:fantia_session)
          has_email = cli.option_present?(:fantia_email)
          has_password = cli.option_present?(:fantia_password)

          if has_email ^ has_password
            raise ValidationError, "fantia requires both --fantia-email and --fantia-password when using login credentials"
          end

          next if has_cookie || has_session || (has_email && has_password)

          raise ValidationError, "fantia requires one of: --fantia-cookie, --fantia-session, or both --fantia-email and --fantia-password"
        end
      },
      "fanbox" => {
        label: "FANBOX",
        description: "Download images from Pixiv FANBOX posts",
        client_class: Clients::Fanbox,
        env_defaults: {
          fanbox_session: "FANBOX_SESSION",
          fanbox_cookie: "FANBOX_COOKIE",
          fanbox_post_info_json: "FANBOX_POST_INFO_JSON",
          fanbox_playwright_browser: "FANBOX_PLAYWRIGHT_BROWSER"
        },
        option_defaults: {
          fanbox_playwright: false
        },
        options_title: "FANBOX options:",
        option_definitions: [
          {
            args: ["--fanbox-session TOKEN", "FANBOXSESSID cookie value"],
            handler: ->(cli, value) { cli.set_option(:fanbox_session, value) }
          },
          {
            args: ["--fanbox-cookie HEADER", "Full FANBOX Cookie header value"],
            handler: ->(cli, value) { cli.set_option(:fanbox_cookie, value) }
          },
          {
            args: ["--fanbox-post-info-json PATH", "Use exported post.info JSON file for FANBOX post payload"],
            handler: ->(cli, value) { cli.set_option(:fanbox_post_info_json, value) }
          },
          {
            args: ["--[no-]fanbox-playwright", "Enable Playwright fallback for FANBOX API 403 responses"],
            handler: ->(cli, value) { cli.set_option(:fanbox_playwright, value) }
          },
          {
            args: ["--fanbox-playwright-browser NAME", "Playwright browser: chromium|firefox|webkit"],
            handler: ->(cli, value) { cli.set_option(:fanbox_playwright_browser, value) }
          }
        ],
        client_builder: lambda { |cli, logger|
          Clients::Fanbox.new(
            session_id: cli.option(:fanbox_session),
            cookie_header: cli.option(:fanbox_cookie),
            post_info_json_path: cli.option(:fanbox_post_info_json),
            playwright: cli.option(:fanbox_playwright),
            playwright_browser: cli.option(:fanbox_playwright_browser),
            logger: logger
          )
        },
        validator: lambda do |cli|
          next if cli.option_present?(:fanbox_session) || cli.option_present?(:fanbox_cookie) || cli.option_present?(:fanbox_post_info_json)

          raise ValidationError, "fanbox requires one of: --fanbox-session, --fanbox-cookie, or --fanbox-post-info-json"
        end
      },
      "myfans" => {
        label: "MyFans",
        description: "Download images or videos from MyFans posts",
        client_class: Clients::Myfans,
        env_defaults: {
          myfans_session: "MYFANS_SESSION",
          myfans_cookie: "MYFANS_COOKIE",
          myfans_playwright_browser: "MYFANS_PLAYWRIGHT_BROWSER"
        },
        option_defaults: {
          myfans_playwright: false
        },
        options_title: "MyFans options:",
        option_definitions: [
          {
            args: ["--myfans-session TOKEN", "MyFans session cookie value"],
            handler: ->(cli, value) { cli.set_option(:myfans_session, value) }
          },
          {
            args: ["--myfans-cookie HEADER", "Full MyFans Cookie header value"],
            handler: ->(cli, value) { cli.set_option(:myfans_cookie, value) }
          },
          {
            args: ["--[no-]myfans-playwright", "Enable Playwright fallback for MyFans video extraction"],
            handler: ->(cli, value) { cli.set_option(:myfans_playwright, value) }
          },
          {
            args: ["--myfans-playwright-browser NAME", "Playwright browser for MyFans: chromium|firefox|webkit"],
            handler: ->(cli, value) { cli.set_option(:myfans_playwright_browser, value) }
          }
        ],
        client_builder: lambda { |cli, logger|
          Clients::Myfans.new(
            session_id: cli.option(:myfans_session),
            cookie_header: cli.option(:myfans_cookie),
            playwright: cli.option(:myfans_playwright),
            playwright_browser: cli.option(:myfans_playwright_browser),
            logger: logger
          )
        },
        validator: lambda do |cli|
          next if cli.option_present?(:myfans_session) || cli.option_present?(:myfans_cookie)

          raise ValidationError, "myfans requires one of: --myfans-session or --myfans-cookie"
        end
      }
    }.freeze
  end
end
