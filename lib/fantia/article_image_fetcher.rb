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
    end

    def run
      validate_url!
      @authenticator&.authenticate!

      html = @client.get(@url)
      doc = Nokogiri::HTML(html)
      image_urls = @extractor.extract(doc, @url)

      if image_urls.empty?
        warn 'No images found in the supplied article.'
        return
      end

      FileUtils.mkdir_p(@output_dir)

      image_urls.each_with_index do |uri, index|
        filename = filename_for(uri, index)
        target = File.join(@output_dir, filename)
        log("Downloading #{uri} -> #{target}")
        @client.download(uri, target)
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
