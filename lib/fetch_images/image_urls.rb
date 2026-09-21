# frozen_string_literal: true

require "cgi"
require "set"
require "uri"

module FetchImages
  IMAGE_EXTENSIONS = %w[.jpg .jpeg .png .gif .bmp .webp].freeze

  module ImageUrls
    def collect_image_urls(data, urls = Set.new)
      case data
      when Hash
        data.each_value { |value| collect_image_urls(value, urls) }
      when Array
        data.each { |value| collect_image_urls(value, urls) }
      when String
        urls << data if looks_like_image_url?(data)
      end
      urls
    end

    def looks_like_image_url?(value)
      uri = URI(value)
      return false unless uri.is_a?(URI::HTTP)

      ext = File.extname(CGI.unescape(uri.path.to_s)).downcase
      IMAGE_EXTENSIONS.include?(ext)
    rescue URI::InvalidURIError
      false
    end
  end
end
