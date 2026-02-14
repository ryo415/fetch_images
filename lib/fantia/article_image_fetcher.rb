# frozen_string_literal: true

require 'fileutils'
require 'nokogiri'
require 'uri'

module Fantia
  class ArticleImageFetcher
    def initialize(url:, output_dir:, client:, extractor:, authenticator: nil, logger: nil)
      @url = parse_url(url)
      @output_dir = output_dir
      @client = client
      @extractor = extractor
      @authenticator = authenticator
      @logger = logger
      log("Initialized article image fetcher for #{@url}")
    end

    def run
      validate_url!
      log("Starting article fetch for #{@url}")

      if @authenticator
        log('Authenticator configured; attempting to sign in before fetching article')
        @authenticator.authenticate!
      else
        log('No authenticator configured; proceeding with existing cookies only')
      end

      html = @client.get(@url)
      log("Fetched article HTML (#{html&.bytesize || 0} bytes)")
      doc = Nokogiri::HTML(html)
      image_urls = @extractor.extract(doc, @url)
      log("Extracted #{image_urls.size} unique image URL(s) from article")
      log("First extracted URLs: #{image_urls.first(5).map(&:to_s).join(', ')}") unless image_urls.empty?

      if image_urls.empty?
        log('Image extraction returned zero results')
        warn 'No images found in the supplied article.'
        return
      end

      FileUtils.mkdir_p(@output_dir)
      log("Ensured output directory exists: #{@output_dir}")

      image_urls.each_with_index do |uri, index|
        filename = filename_for(uri, index)
        target = File.join(@output_dir, filename)
        log("Downloading #{uri} -> #{target}")
        @client.download(uri, target, referer: @url)
      end
    end

    private

    def parse_url(url)
      URI.parse(url)
    rescue URI::InvalidURIError
      raise ArgumentError, 'The provided URL is not valid.'
    end

    def validate_url!
      unless %w[http https].include?(@url.scheme)
        raise ArgumentError, 'URL must start with http:// or https://'
      end

      return if @url.host&.include?('fantia.jp')

      raise ArgumentError, 'The provided URL does not appear to be a Fantia article.'
    end

    def filename_for(uri, index)
      base = File.basename(uri.path)
      base = "image_#{index + 1}" if base.nil? || base.empty? || base == '/'

      if File.exist?(File.join(@output_dir, base))
        ext = File.extname(base)
        stem = File.basename(base, ext)
        counter = 1
        new_base = nil

        loop do
          new_base = format('%s_%02d%s', stem, counter, ext)
          break unless File.exist?(File.join(@output_dir, new_base))

          counter += 1
        end

        base = new_base
      end

      base
    end

    def log(message)
      @logger&.call(message)
    end
  end
end
