# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class HlsDownloaderTest < Minitest::Test
  URL = "https://media.example.test/a.m3u8"

  def test_hls_moves_completed_video_and_keeps_exact_command_headers_and_log
    Dir.mktmpdir do |directory|
      path = File.join(directory, "001_video.mp4")
      tmp_path = "#{path}.tmp.mp4"
      process_status = status(success: true)
      messages = []
      capture = lambda do |*command|
        assert_equal [
          "/fake/ffmpeg",
          "-y",
          "-loglevel", "error",
          "-headers", "Referer: https://myfans.jp/posts/42\r\n",
          "-i", URL,
          "-c", "copy",
          "-bsf:a", "aac_adtstoasc",
          tmp_path
        ], command
        File.write(command.last, "mp4")
        ["", "", process_status]
      end
      downloader = FetchImages::Clients::Myfans::HlsDownloader.new(
        capture: capture,
        logger: ->(message) { messages << message }
      )

      assert_equal path, downloader.download(
        URL,
        path,
        executable: "/fake/ffmpeg",
        headers: { "Referer" => "https://myfans.jp/posts/42", "Cookie" => "" }
      )
      assert_equal "mp4", File.read(path)
      assert_equal ["001_video.mp4"], Dir.children(directory)
      assert_equal ["MyFans ffmpeg: /fake/ffmpeg -i #{URL} -> #{path}"], messages
    end
  end

  def test_nonzero_exit_uses_stderr_then_stdout_then_unknown_and_preserves_output
    cases = [
      ["stdout detail\n", "stderr detail\n", "stderr detail"],
      ["stdout detail\n", " \n", "stdout detail"],
      [" \n", "", "unknown error"]
    ]

    cases.each do |stdout, stderr, detail|
      capture = lambda do |*command|
        File.write(command.last, "partial")
        [stdout, stderr, status(success: false)]
      end
      downloader = FetchImages::Clients::Myfans::HlsDownloader.new(capture: capture)

      Dir.mktmpdir do |directory|
        path = File.join(directory, "001_video.mp4")
        File.write(path, "existing")

        error = assert_raises(RuntimeError) do
          downloader.download(URL, path, executable: "/fake/ffmpeg", headers: {})
        end

        assert_equal "ffmpeg failed: #{detail}", error.message
        assert_equal "existing", File.read(path)
        refute File.exist?("#{path}.tmp.mp4")
      end
    end
  end

  def test_missing_executable_raises_before_capture
    downloader = FetchImages::Clients::Myfans::HlsDownloader.new(
      capture: ->(*) { flunk "capture must not run" }
    )

    error = assert_raises(RuntimeError) do
      downloader.download(URL, "/unused/video.mp4", executable: nil, headers: {})
    end

    assert_equal "ffmpeg not found (install ffmpeg to save MyFans HLS as mp4)", error.message
  end

  def test_hls_downloader_can_be_required_before_client
    script = <<~'RUBY'
      require "fetch_images/clients/myfans/hls_downloader"
      require "fetch_images/clients/myfans"
      abort "wrong Myfans superclass" unless FetchImages::Clients::Myfans.superclass == FetchImages::Client
      abort "HlsDownloader inherited Client" if FetchImages::Clients::Myfans::HlsDownloader < FetchImages::Client
    RUBY

    _stdout, stderr, process_status = Open3.capture3(
      RbConfig.ruby,
      "-I#{File.expand_path('../lib', __dir__)}",
      "-e",
      script
    )

    assert process_status.success?, stderr
  end

  private

  def status(success:)
    Object.new.tap do |process_status|
      process_status.define_singleton_method(:success?) { success }
    end
  end
end
