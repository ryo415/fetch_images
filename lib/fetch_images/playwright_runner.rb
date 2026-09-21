# frozen_string_literal: true

require "json"
require "open3"
require "tmpdir"

module FetchImages
  class PlaywrightRunner
    def initialize(capture: Open3.method(:capture3))
      @capture = capture
    end

    def run(node:, script:, args:, env:)
      Dir.mktmpdir("fetch-images-playwright-") do |directory|
        output = File.join(directory, "result.json")
        stdout, stderr, status = @capture.call(env, node, script, *args, "--output", output)
        yield(stdout, stderr, status) if block_given?
        next nil unless status.success?

        JSON.parse(File.read(output))
      end
    end
  end
end
