# frozen_string_literal: true

require_relative "test_helper"

class ClientDownloadsTest < Minitest::Test
  include ClientFixtures

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
end
