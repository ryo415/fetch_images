# frozen_string_literal: true

require_relative "test_helper"

class ClientDownloadsTest < Minitest::Test
  include ClientFixtures

  def test_dry_run_does_not_create_post_directory
    Dir.mktmpdir do |dir|
      result = download_client.download_images("https://example.test/posts/42", dir, dry_run: true)

      assert_equal ["https://media.example.test/image"], result.planned
      assert_empty Dir.children(dir)
    end
  end

  def test_overwrite_false_skips_existing_file_found_by_extension
    Dir.mktmpdir do |dir|
      post_dir = File.join(dir, "post")
      FileUtils.mkdir_p(post_dir)
      existing_path = File.join(post_dir, "001_image.jpg")
      File.write(existing_path, "original")

      result = download_client.download_images("https://example.test/posts/42", dir)

      assert_empty result.downloaded
      assert_equal [existing_path], result.skipped
      assert_equal "original", File.read(existing_path)
    end
  end

  def test_overwrite_true_downloads_existing_file_again
    Dir.mktmpdir do |dir|
      post_dir = File.join(dir, "post")
      FileUtils.mkdir_p(post_dir)
      existing_path = File.join(post_dir, "001_image.jpg")
      File.write(existing_path, "original")

      result = download_client.download_images("https://example.test/posts/42", dir, overwrite: true)

      assert_equal [existing_path], result.downloaded
      assert_empty result.skipped
      assert_equal "new", File.read(existing_path)
    end
  end

  def test_myfans_continues_after_one_download_fails
    payload = { "url" => "https://myfans.jp/posts/42", "html" =>
      '<video src="https://media.example.test/a.mp4"></video><video src="https://media.example.test/b.mp4"></video>' }
    client = client_with_payload(FetchImages::Clients::Myfans, payload)
    client.define_singleton_method(:download_file) do |url, path, **_|
      raise "download failed" if url.end_with?("a.mp4")

      File.write(path, "video")
      path
    end

    Dir.mktmpdir do |dir|
      result = client.download_images(payload["url"], dir)
      assert_equal 2, result.planned.length
      assert_equal [File.join(dir, "post", "002_b.mp4")], result.downloaded
      assert_equal "video", File.read(result.downloaded.first)
    end
  end

  private

  def download_client
    FetchImages::Client.new.tap do |client|
      client.define_singleton_method(:fetch_post_payload) { |_| ["42", {}] }
      client.define_singleton_method(:extract_image_urls) { |_| ["https://media.example.test/image"] }
      client.define_singleton_method(:make_post_directory_name) { |*| "post" }
      client.define_singleton_method(:download_file) do |_, path, **|
        saved_path = "#{path}.jpg"
        File.write(saved_path, "new")
        saved_path
      end
    end
  end
end
