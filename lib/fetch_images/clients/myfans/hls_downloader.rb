# frozen_string_literal: true

require "fileutils"
require "open3"
require_relative "../../client"

module FetchImages
  module Clients
    class Myfans < Client
      class HlsDownloader
        def initialize(capture: Open3.method(:capture3), logger: nil)
          @capture = capture
          @logger = logger
        end

        def download(url, path, executable:, headers:)
          raise "ffmpeg not found (install ffmpeg to save MyFans HLS as mp4)" unless executable

          header_text = headers.each_with_object(+"") do |(key, value), memo|
            next if value.to_s.empty?

            memo << "#{key}: #{value}\r\n"
          end

          tmp_path = "#{path}.tmp.mp4"
          command = [
            executable,
            "-y",
            "-loglevel", "error",
            "-headers", header_text,
            "-i", url,
            "-c", "copy",
            "-bsf:a", "aac_adtstoasc",
            tmp_path
          ]
          @logger&.call("MyFans ffmpeg: #{executable} -i #{url} -> #{path}")
          stdout, stderr, status = @capture.call(*command)
          unless status.success?
            message = stderr.to_s.strip
            message = stdout.to_s.strip if message.empty?
            message = "unknown error" if message.empty?
            raise "ffmpeg failed: #{message}"
          end

          FileUtils.mv(tmp_path, path)
          path
        ensure
          File.delete(tmp_path) if defined?(tmp_path) && tmp_path && File.exist?(tmp_path)
        end
      end
    end
  end
end
