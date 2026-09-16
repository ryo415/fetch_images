# frozen_string_literal: true

require_relative "test_helper"

class FanboxExtractorTest < Minitest::Test
  def test_image_map_filters_creator_assets
    image = "https://downloads.fanbox.cc/images/post/42/a.jpg"
    payload = {
      "body" => {
        "imageMap" => {
          "a" => { "originalUrl" => image },
          "icon" => { "originalUrl" => "https://downloads.fanbox.cc/images/creator/icon.jpg" }
        }
      }
    }

    assert_equal [image], FetchImages::Clients::Fanbox.new.send(:extract_image_urls, payload)
  end

  def test_metadata_parsing_handles_missing_and_invalid_json
    extractor = FetchImages::Clients::Fanbox::Extractor.new

    assert_nil extractor.extract_csrf_token_from_metadata("<html></html>")
    assert_nil extractor.extract_csrf_token_from_metadata('<meta id="metadata" content="broken">')
    assert_equal "dummy", extractor.extract_csrf_token_from_metadata(
      %q(<meta id="metadata" content='{"csrfToken":"dummy"}'>)
    )
  end

  def test_manual_json_dry_run_does_not_make_http_requests
    Dir.mktmpdir do |dir|
      image = "https://downloads.fanbox.cc/images/post/42/a.jpg"
      json_path = File.join(dir, "post.json")
      File.write(json_path, JSON.generate({ "body" => { "body" => { "images" => [{ "originalUrl" => image }] } } }))
      client = FetchImages::Clients::Fanbox.new(post_info_json_path: json_path)
      client.define_singleton_method(:http_get) { |*_, **_| raise "unexpected HTTP" }

      result = client.download_images("https://creator.fanbox.cc/posts/42", dir, dry_run: true)

      assert_equal [image], result.planned
    end
  end
end
