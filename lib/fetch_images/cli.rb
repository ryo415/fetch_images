# frozen_string_literal: true

require "fileutils"
require "optparse"

module FetchImages
  class CLI
    DEFAULT_OUTPUT_DIR = File.expand_path("downloads")

    def self.build_credentials(email, password)
      return nil if email.to_s.empty? || password.to_s.empty?

      { email: email, password: password }
    end

    def initialize(argv)
      @argv = argv
      @options = default_options
    end

    def run
      parser = build_parser
      urls = parser.parse!(@argv)
      if urls.empty?
        puts parser
        return 1
      end

      FileUtils.mkdir_p(@options[:output])
      logger = Logger.build(verbose: @options[:verbose], log_file: @options[:log_file])
      warn "Debug log file: #{logger.path}" if logger

      run_downloads(urls, build_clients(logger))
    ensure
      logger&.close
    end

    private

    def default_options
      {
        output: DEFAULT_OUTPUT_DIR,
        fantia_session: ENV["FANTIA_SESSION"],
        fantia_cookie: ENV["FANTIA_COOKIE"],
        fantia_email: ENV["FANTIA_EMAIL"],
        fantia_password: ENV["FANTIA_PASSWORD"],
        fanbox_session: ENV["FANBOX_SESSION"],
        fanbox_cookie: ENV["FANBOX_COOKIE"],
        fanbox_post_info_json: ENV["FANBOX_POST_INFO_JSON"],
        fanbox_playwright: false,
        fanbox_playwright_browser: ENV["FANBOX_PLAYWRIGHT_BROWSER"],
        myfans_session: ENV["MYFANS_SESSION"],
        myfans_cookie: ENV["MYFANS_COOKIE"],
        myfans_playwright: false,
        myfans_playwright_browser: ENV["MYFANS_PLAYWRIGHT_BROWSER"],
        overwrite: false,
        dry_run: false,
        verbose: false,
        log_file: nil
      }
    end

    def build_clients(logger)
      [
        Clients::Fantia.new(
          session_id: @options[:fantia_session],
          cookie_header: @options[:fantia_cookie],
          credentials: self.class.build_credentials(@options[:fantia_email], @options[:fantia_password]),
          logger: logger
        ),
        Clients::Fanbox.new(
          session_id: @options[:fanbox_session],
          cookie_header: @options[:fanbox_cookie],
          post_info_json_path: @options[:fanbox_post_info_json],
          playwright: @options[:fanbox_playwright],
          playwright_browser: @options[:fanbox_playwright_browser],
          logger: logger
        ),
        Clients::Myfans.new(
          session_id: @options[:myfans_session],
          cookie_header: @options[:myfans_cookie],
          playwright: @options[:myfans_playwright],
          playwright_browser: @options[:myfans_playwright_browser],
          logger: logger
        )
      ]
    end

    def run_downloads(urls, clients)
      exit_code = 0

      urls.each do |url|
        begin
          handle_download(url, clients)
        rescue AuthenticationError, UnsupportedUrlError => e
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
      OptionParser.new do |opts|
        opts.banner = "Usage: fetch_images [options] URL [URL ...]"
        opts.on("-o", "--output DIR", "Directory for downloaded files (default: ./downloads)") do |dir|
          @options[:output] = File.expand_path(dir)
        end
        opts.on("--fantia-session TOKEN", "Fantia _session_id cookie value") do |token|
          @options[:fantia_session] = token
        end
        opts.on("--fantia-cookie HEADER", "Full Fantia Cookie header value") do |header|
          @options[:fantia_cookie] = header
        end
        opts.on("--fantia-email EMAIL", "Fantia account email for login") do |email|
          @options[:fantia_email] = email
        end
        opts.on("--fantia-password PASSWORD", "Fantia account password for login") do |password|
          @options[:fantia_password] = password
        end
        opts.on("--fanbox-session TOKEN", "FANBOXSESSID cookie value") do |token|
          @options[:fanbox_session] = token
        end
        opts.on("--fanbox-cookie HEADER", "Full FANBOX Cookie header value") do |header|
          @options[:fanbox_cookie] = header
        end
        opts.on("--fanbox-post-info-json PATH", "Use exported post.info JSON file for FANBOX post payload") do |path|
          @options[:fanbox_post_info_json] = path
        end
        opts.on("--fanbox-playwright", "Enable Playwright fallback for FANBOX API 403 responses") do
          @options[:fanbox_playwright] = true
        end
        opts.on("--fanbox-playwright-browser NAME", "Playwright browser: chromium|firefox|webkit") do |name|
          @options[:fanbox_playwright_browser] = name
        end
        opts.on("--myfans-session TOKEN", "MyFans session cookie value") do |token|
          @options[:myfans_session] = token
        end
        opts.on("--myfans-cookie HEADER", "Full MyFans Cookie header value") do |header|
          @options[:myfans_cookie] = header
        end
        opts.on("--myfans-playwright", "Enable Playwright fallback for MyFans video extraction") do
          @options[:myfans_playwright] = true
        end
        opts.on("--myfans-playwright-browser NAME", "Playwright browser for MyFans: chromium|firefox|webkit") do |name|
          @options[:myfans_playwright_browser] = name
        end
        opts.on("--overwrite", "Overwrite existing files") do
          @options[:overwrite] = true
        end
        opts.on("--dry-run", "List files without downloading") do
          @options[:dry_run] = true
        end
        opts.on("-v", "--verbose", "Enable debug logging") do
          @options[:verbose] = true
        end
        opts.on("--log-file PATH", "Write logs to file (default: ./fetch_images.log when --verbose)") do |path|
          @options[:log_file] = path
        end
        opts.on("-h", "--help", "Show this help message") do
          puts opts
          exit
        end
      end
    end

    def handle_download(url, clients)
      client = clients.find { |candidate| candidate.supports_url?(url) }
      raise UnsupportedUrlError, url unless client

      result = client.download_images(url, @options[:output], overwrite: @options[:overwrite], dry_run: @options[:dry_run])
      if @options[:dry_run]
        puts "Dry run: would download #{result.planned.length} file(s) from #{url}"
      elsif result.downloaded.any?
        puts "Downloaded #{result.downloaded.length} file(s) from #{url}"
      elsif result.skipped.any?
        puts "Skipped #{result.skipped.length} existing file(s) for #{url}"
      else
        puts "No downloadable files found for #{url}"
      end
    end
  end
end
