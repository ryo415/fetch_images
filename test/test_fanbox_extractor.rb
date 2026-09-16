# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

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

  def test_extract_image_urls_preserves_original_map_body_cover_precedence
    original = "https://downloads.fanbox.cc/images/post/42/original.jpg"
    mapped = "https://downloads.fanbox.cc/images/post/42/mapped.jpg"
    nested = "https://downloads.fanbox.cc/images/post/42/nested.jpg"
    cover = "https://downloads.fanbox.cc/images/post/42/cover.jpg"
    extractor = FetchImages::Clients::Fanbox::Extractor.new

    payload = {
      "body" => {
        "coverImageUrl" => cover,
        "imageMap" => { "mapped" => { "originalUrl" => mapped } },
        "body" => {
          "images" => [{ "originalUrl" => original }],
          "nested" => { "originalUrl" => nested }
        }
      }
    }
    assert_equal [original], extractor.extract_image_urls(payload)

    payload["body"]["body"].delete("images")
    assert_equal [mapped], extractor.extract_image_urls(payload)

    payload["body"].delete("imageMap")
    assert_equal [nested], extractor.extract_image_urls(payload)

    payload["body"].delete("body")
    assert_equal [cover], extractor.extract_image_urls(payload)
  end

  def test_extractor_can_be_required_before_client
    script = <<~'RUBY'
      require "fetch_images/clients/fanbox/extractor"
      require "fetch_images/clients/fanbox"
      abort "wrong Fanbox superclass" unless FetchImages::Clients::Fanbox.superclass == FetchImages::Client
      abort "extractor inherited Client" if FetchImages::Clients::Fanbox::Extractor < FetchImages::Client
    RUBY

    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-I#{File.expand_path('../lib', __dir__)}",
      "-e",
      script
    )

    assert status.success?, stderr
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
