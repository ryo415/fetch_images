# frozen_string_literal: true

require "optparse"

module FetchImages
  class CLI
    DEFAULT_OUTPUT_DIR = OptionResolver::DEFAULT_OUTPUT_DIR
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

    def self.build_credentials(email, password)
      OptionResolver.build_credentials(email, password)
    end

    def initialize(argv, input: $stdin, output: $stdout, error: $stderr, strict_results: false)
      @argv = argv.dup
      @input, @output, @error = input, output, error
      @strict_results = strict_results
      @subcommand = nil
      @explicit_options = {}
      @reporter = Reporter.new(output: output, error: error, prefixed: strict_results)
    end

    def run
      if %w[auth config].include?(@argv.first)
        return SettingsCommand.new(@argv.shift, @argv, input: @input, output: @output).run
      end
      return run_queue if @argv.first == "queue"

      extract_subcommand!
      @options = OptionResolver.new(site: @subcommand, commands: COMMANDS)
      parser = build_parser
      urls = parser.parse!(@argv)
      validate_command!(urls)

      DownloadRunner.new(
        site: @subcommand, command: command_config, options: @options,
        reporter: @reporter, strict_results: @strict_results,
        client_builder: method(:build_client)
      ).run(urls)
    rescue OptionParser::ParseError, ValidationError, SystemCallError => e
      warn e.message
      puts parser if parser
      1
    end

    def set_option(key, value)
      @explicit_options[key] = value
      @options&.set_option(key, value)
    end

    def option(key)
      @options ? @options.option(key) : @explicit_options[key]
    end

    def option_present?(key)
      !option(key).to_s.strip.empty?
    end

    private

    def puts(message)
      @reporter.message(message)
    end

    def warn(message)
      @reporter.warning(message)
    end

    def run_queue
      @argv.shift
      help = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: fetch_images queue [options] < urls.txt (or paste URLs interactively)"
        add_option_group(opts, "Common options:", COMMON_OPTION_DEFINITIONS)
        opts.on("-h", "--help", "Show help") { help = true }
      end
      remaining = parser.parse!(@argv)
      if help
        puts(parser)
        return 0
      end
      raise ValidationError, "queue reads URLs from standard input; do not pass URL arguments" unless remaining.empty?

      DownloadQueue.new(input: @input, output: @output) do |site, url|
        run_queued_download(site, url)
      end.run
    rescue Interrupt
      warn "[INFO]   Queue interrupted. Unfinished URLs must be added again."
      130
    end

    def run_queued_download(site, url)
      reporter = Reporter.new(output: @output, error: @error, prefixed: true)
      options = OptionResolver.new(site: site, commands: COMMANDS)
      parser = build_subcommand_parser(site)
      @explicit_options.each { |key, value| options.set_option(key, value) }
      DownloadRunner.new(
        site: site, command: COMMANDS.fetch(site), options: options,
        reporter: reporter, strict_results: true
      ).run([url])
    rescue ValidationError, SystemCallError => e
      reporter.warning(e.message)
      reporter.message(parser) if parser
      1
    end

    def build_client(logger)
      command_config.fetch(:client_builder).call(@options, logger)
    end

    def build_parser
      return build_root_parser unless @subcommand

      build_subcommand_parser
    end

    def build_root_parser
      OptionParser.new do |opts|
        opts.banner = <<~BANNER
          Usage: fetch_images <subcommand> [options] URL [URL ...]

          Subcommands:
        BANNER
        COMMANDS.each do |name, config|
          opts.separator format("  %-8s %s", name, config.fetch(:description))
        end
        opts.separator "  auth     Register/update Cookie (auth <site> [--clear])"
        opts.separator "  config   Save site defaults (config <site> --help)"
        opts.separator "  queue    Accept mixed-site post URLs until :quit / EOF"
        opts.on("-h", "--help", "Show this help message") { puts opts; exit }
      end
    end

    def build_subcommand_parser(site = @subcommand)
      OptionParser.new do |opts|
        opts.banner = "Usage: fetch_images #{site} [options] URL [URL ...]"
        add_option_group(opts, "Common options:", COMMON_OPTION_DEFINITIONS)
        add_option_group(opts, COMMANDS.fetch(site).fetch(:options_title), COMMANDS.fetch(site).fetch(:option_definitions))
        opts.on("-h", "--help", "Show this help message") { puts opts; exit }
      end
    end

    def add_option_group(opts, title, definitions)
      opts.separator ""
      opts.separator title
      definitions.each do |definition|
        register_option(opts, definition)
      end
    end

    def register_option(opts, definition)
      args = definition.fetch(:args)
      handler = definition.fetch(:handler)
      opts.on(*args) { |value| handler.call(self, value) }
    end

    def extract_subcommand!
      first = @argv.first.to_s
      return if first.empty?
      return if %w[-h --help].include?(first)

      unless COMMANDS.key?(first)
        raise ValidationError, "Subcommand is required: choose one of #{COMMANDS.keys.join(', ')}"
      end

      @subcommand = @argv.shift
    end

    def validate_command!(urls)
      raise ValidationError, "Subcommand is required: choose one of #{COMMANDS.keys.join(', ')}" unless @subcommand
      raise ValidationError, "At least one URL is required" if urls.empty?

    end

    def command_config
      COMMANDS.fetch(@subcommand)
    end

  end
end
