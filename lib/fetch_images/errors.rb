# frozen_string_literal: true

module FetchImages
  class UnsupportedUrlError < StandardError
    attr_reader :url

    def initialize(url)
      super("Unsupported URL: #{url}")
      @url = url
    end
  end
end
