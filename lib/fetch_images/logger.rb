# frozen_string_literal: true

module FetchImages
  class Logger
    def self.build(verbose: false, log_file: nil)
      path = log_file.to_s.strip
      return nil if !verbose && path.empty?

      path = File.expand_path("fetch_images.log") if path.empty?
      new(path: path, verbose: verbose)
    end

    attr_reader :path

    def initialize(path:, verbose: false)
      @path = path
      @verbose = verbose
      @io = File.open(path, "a")
      @io.sync = true
    end

    def call(message)
      timestamp = Time.now.strftime("%Y-%m-%d %H:%M:%S")
      line = "[#{timestamp}] #{message}"
      warn line if @verbose
      @io.puts(line)
    end

    def close
      return if @io.closed?

      @io.close
    end
  end
end
