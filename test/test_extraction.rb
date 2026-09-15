# frozen_string_literal: true

require_relative "test_helper"

class ExtractionTest < Minitest::Test
  include ClientFixtures

  def test_fantia_keeps_main_variant_in_input_group_order
    base = "https://c.fantia.jp/uploads/post_content_photo/file/42/"
    payload = { "post_contents" => [{ "images" => [
      "#{base}small_a.jpg", "#{base}main_a.jpg", "#{base}large_b.jpg"
    ] }] }
    client = client_with_payload(FetchImages::Clients::Fantia, payload)
    result = client.download_images("https://fantia.jp/posts/42", "/unused", dry_run: true)
    assert_equal ["#{base}main_a.jpg", "#{base}large_b.jpg"], result.planned
  end

  def test_fanbox_prefers_original_images_over_cover
    original = "https://downloads.example.test/original.jpg"
    payload = { "body" => { "coverImageUrl" => "https://example.test/cover.jpg",
                            "body" => { "images" => [{ "originalUrl" => original }] } } }
    client = client_with_payload(FetchImages::Clients::Fanbox, payload)
    result = client.download_images("https://creator.fanbox.cc/posts/42", "/unused", dry_run: true)
    assert_equal [original], result.planned
  end

  def test_myfans_prefers_video_over_image
    payload = { "url" => "https://myfans.jp/posts/42", "html" =>
      '<video src="https://media.example.test/a.mp4"></video><img src="https://media.example.test/a.jpg">' }
    client = client_with_payload(FetchImages::Clients::Myfans, payload)
    result = client.download_images(payload["url"], "/unused", dry_run: true)
    assert_equal ["https://media.example.test/a.mp4"], result.planned
  end
end
