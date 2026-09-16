# frozen_string_literal: true

require "optparse"

module FetchImages
  class CLI
    DEFAULT_OUTPUT_DIR = OptionResolver::DEFAULT_OUTPUT_DIR
    COMMON_OPTION_DEFINITIONS = SiteDefinitions::COMMON_OPTION_DEFINITIONS
    COMMANDS = SiteDefinitions::COMMANDS

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
