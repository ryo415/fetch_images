# frozen_string_literal: true

require_relative "test_helper"

class FileStorageTest < Minitest::Test
  def test_build_filename_and_name_sanitizers
    storage = FetchImages::FileStorage.new

    assert_equal "007_my image.jpg", storage.build_filename("https://example.test/my%20image.jpg", 7)
    assert_equal "hello-world", storage.slugify(" hello world ")
    assert_equal "日本語 _ title", storage.sanitize_directory_name("日本語 / title.")
    assert_equal "fallback", storage.sanitize_directory_name("...", fallback: "fallback")
    assert_equal "path_name", storage.sanitize_filename("path/name...")
  end

  def test_extensions_and_existing_path
    storage = FetchImages::FileStorage.new
    extensions = {
      "image/jpeg" => ".jpg",
      "image/png" => ".png",
      "image/webp" => ".webp",
      "image/gif" => ".gif",
      "image/bmp" => ".bmp",
      "image/avif" => ".avif",
      "video/mp4" => ".mp4",
      "video/webm" => ".webm",
      "application/vnd.apple.mpegurl" => ".m3u8",
      "application/x-mpegurl" => ".m3u8",
      "application/octet-stream" => ".img"
    }

    extensions.each do |content_type, extension|
      assert_equal "001_a#{extension}", storage.ensure_extension("001_a", content_type)
    end
    assert_equal "001_a.bin", storage.ensure_extension("001_a.bin", "image/jpeg")

    Dir.mktmpdir do |dir|
      path = File.join(dir, "001_a")
      File.write("#{path}.jpg", "saved")
      assert_equal "#{path}.jpg", storage.existing_download_path(path)
      assert_nil storage.existing_download_path(File.join(dir, "missing"))
    end
  end

  def test_interrupted_response_keeps_existing_file_and_cleans_temporary_file
    response = Object.new
    response.define_singleton_method(:[]) { |_| "image/jpeg" }
    response.define_singleton_method(:read_body) do |&block|
      block.call("partial")
      raise IOError, "interrupted"
    end
    storage = FetchImages::FileStorage.new

    Dir.mktmpdir do |dir|
      path = File.join(dir, "001_image.jpg")
      File.write(path, "original")

      assert_raises(IOError) { storage.save_response(path, response) }
      assert_equal "original", File.read(path)
      assert_equal ["001_image.jpg"], Dir.children(dir)
    end
  end
end
