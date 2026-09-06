# frozen_string_literal: true

require "fileutils"

module FetchImages
  class DownloadRunner
    def initialize(site:, command:, options:, reporter:, strict_results: false, client_builder: nil)
      @site, @command, @options, @reporter = site, command, options, reporter
      @strict_results = strict_results
      @client_builder = client_builder || ->(logger) { command.fetch(:client_builder).call(options, logger) }
    end

    def run(urls)
      @command.fetch(:validator).call(@options)
      FileUtils.mkdir_p(@options.option(:output))
      logger = Logger.build(verbose: @options.option(:verbose), log_file: @options.option(:log_file))
      @reporter.warning("Debug log file: #{logger.path}") if logger
      client = @client_builder.call(logger)
      exit_code = 0
      urls.each do |url|
        begin
          download(url, client)
        rescue AuthenticationError, UnsupportedUrlError, ValidationError => e
          @reporter.warning(e.message)
          exit_code = 1
        rescue StandardError => e
          @reporter.warning("Error while processing #{url}: #{e.message}")
          exit_code = 1
        end
      end
      exit_code
    ensure
      logger&.close
    end

    private

    def download(url, client)
      unless client.supports_url?(url)
        raise ValidationError, "#{@site} subcommand requires a #{@command.fetch(:label)} post URL: #{url}"
      end

      dry_run = @options.option(:dry_run)
      result = client.download_images(url, @options.option(:output), overwrite: @options.option(:overwrite), dry_run: dry_run)
      @reporter.result(url, result, dry_run: dry_run)
      if @strict_results && (result.planned.empty? ||
          (!dry_run && result.downloaded.length + result.skipped.length < result.planned.length))
        raise ValidationError, "No files found or download incomplete. Check access/Cookie; use auth #{@site} to update Cookie."
      end
    end
  end
end
