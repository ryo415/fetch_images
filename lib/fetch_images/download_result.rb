# frozen_string_literal: true

module FetchImages
  class DownloadResult
    attr_reader :planned, :downloaded, :skipped

    def initialize(planned: [], downloaded: [], skipped: [])
      @planned = planned
      @downloaded = downloaded
      @skipped = skipped
    end
  end
end
