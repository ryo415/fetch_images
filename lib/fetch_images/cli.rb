# frozen_string_literal: true

require "fileutils"
require "optparse"

module FetchImages
  class CLI
    DEFAULT_OUTPUT_DIR = File.expand_path("downloads")
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
      return nil if email.to_s.empty? || password.to_s.empty?

      { email: email, password: password }
    end

    def initialize(argv, input: $stdin, output: $stdout, error: $stderr, strict_results: false)
      @argv = argv.dup
      @input, @output, @error = input, output, error
      @strict_results = strict_results
      @subcommand = nil
      @explicit_auth = {}
    end

    def run
      if %w[auth config].include?(@argv.first)
        return SettingsCommand.new(@argv.shift, @argv, input: @input, output: @output).run
      end
      return run_queue if @argv.first == "queue"

      extract_subcommand!
      @options = build_default_options
      parser = build_parser
      urls = parser.parse!(@argv)
      validate_command!(urls)

      FileUtils.mkdir_p(option(:output))
      logger = Logger.build(verbose: option(:verbose), log_file: option(:log_file))
      warn "Debug log file: #{logger.path}" if logger

      run_downloads(urls, build_client(logger))
    rescue OptionParser::ParseError, ValidationError, SystemCallError => e
      warn e.message
      puts parser if parser
      1
    ensure
      logger&.close
    end

    def set_option(key, value)
      site = key.to_s.split("_").first
      if authentication_keys(site).include?(key) && !@explicit_auth[site]
        authentication_keys(site).each { |auth_key| @options[auth_key] = nil }
        @explicit_auth[site] = true
      end
      @options[key] = value
    end

    def option(key)
      @options[key]
    end

    def option_present?(key)
      !option(key).to_s.strip.empty?
    end

    private

    def puts(message)
      if @strict_results
        message.to_s.each_line { |line| @output.puts("[RESULT] #{line.chomp}") }
      else
        @output.puts(message)
      end
    end

    def warn(message)
      if @strict_results
        message.to_s.each_line { |line| @error.puts("[ERROR]  #{line.chomp}") }
      else
        @error.puts(message)
      end
    end

    def authentication_keys(site)
      %w[cookie session email password post_info_json].map { |name| "#{site}_#{name}".to_sym }
    end

    def run_queue
      @argv.shift
      @options = {}
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

      args = []
      args.concat(["--output", option(:output)]) if option(:output)
      args.concat(["--log-file", option(:log_file)]) if option(:log_file)
      %i[overwrite dry_run verbose].each { |key| args << "--#{key.to_s.tr('_', '-')}" if option(key) }
      DownloadQueue.new(input: @input, output: @output) do |site, url|
        self.class.new([site, *args, url], input: @input, output: @output, error: @error, strict_results: true).run
      end.run
    rescue Interrupt
      warn "[INFO]   Queue interrupted. Unfinished URLs must be added again."
      130
    end

    def build_default_options
      options = {
        output: DEFAULT_OUTPUT_DIR,
        overwrite: false,
        dry_run: false,
        verbose: false,
        log_file: nil
      }

      if @subcommand
        saved = Settings.new.for_site(@subcommand)
        options[:output] = saved["output"] if saved.key?("output")
        options["#{@subcommand}_cookie".to_sym] = saved["cookie"]
        options["#{@subcommand}_playwright".to_sym] = saved["playwright"] if saved.key?("playwright")
        options["#{@subcommand}_playwright_browser".to_sym] = saved["browser"] if saved.key?("browser")
      end
      COMMANDS.each do |site, command|
        auth_keys = authentication_keys(site)
        env = command.fetch(:env_defaults, {})
        if env.any? { |key, name| auth_keys.include?(key) && !ENV[name].to_s.strip.empty? }
          auth_keys.each { |key| options[key] = nil }
        end
        command.fetch(:env_defaults, {}).each do |key, env_name|
          options[key] = ENV[env_name] unless ENV[env_name].to_s.strip.empty?
        end
        command.fetch(:option_defaults, {}).each do |key, value|
          options[key] = value unless options.key?(key)
        end
      end

      options
    end

    def build_client(logger)
      command_config.fetch(:client_builder).call(self, logger)
    end

    def run_downloads(urls, client)
      exit_code = 0

      urls.each do |url|
        begin
          handle_download(url, client)
        rescue AuthenticationError, UnsupportedUrlError, ValidationError => e
          warn e.message
          exit_code = 1
        rescue StandardError => e
          warn "Error while processing #{url}: #{e.message}"
          exit_code = 1
        end
      end

      exit_code
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

    def build_subcommand_parser
      OptionParser.new do |opts|
        opts.banner = "Usage: fetch_images #{@subcommand} [options] URL [URL ...]"
        add_option_group(opts, "Common options:", COMMON_OPTION_DEFINITIONS)
        add_option_group(opts, command_config.fetch(:options_title), command_config.fetch(:option_definitions))
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

    def handle_download(url, client)
      raise ValidationError, mismatch_error_message(url) unless client.supports_url?(url)

      result = client.download_images(url, option(:output), overwrite: option(:overwrite), dry_run: option(:dry_run))
      puts(download_result_message(url, result))
      if @strict_results && (result.planned.empty? ||
          (!option(:dry_run) && result.downloaded.length + result.skipped.length < result.planned.length))
        raise ValidationError, "No files found or download incomplete. Check access/Cookie; use auth #{@subcommand} to update Cookie."
      end
    end

    def download_result_message(url, result)
      if option(:dry_run)
        "Dry run: would download #{result.planned.length} file(s) from #{url}"
      elsif result.downloaded.any?
        "Downloaded #{result.downloaded.length} file(s) from #{url}"
      elsif result.skipped.any?
        "Skipped #{result.skipped.length} existing file(s) for #{url}"
      else
        "No downloadable files found for #{url}"
      end
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

      command_config.fetch(:validator).call(self)
    end

    def command_config
      COMMANDS.fetch(@subcommand)
    end

    def mismatch_error_message(url)
      "#{@subcommand} subcommand requires a #{command_config.fetch(:label)} post URL: #{url}"
    end
  end
end
