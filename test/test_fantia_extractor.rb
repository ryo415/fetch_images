# frozen_string_literal: true

require_relative "test_helper"

class FantiaExtractorTest < Minitest::Test
  def setup
    @client = FetchImages::Clients::Fantia.new
    @extractor = FetchImages::Clients::Fantia::Extractor.new
  end

  def test_api_images_keep_the_preferred_variant_for_each_image
    base = "https://c.fantia.jp/uploads/post_content_photo/file/42/"
    payload = { "post_contents" => [{ "images" => [
      "#{base}small_a.jpg",
      "#{base}main_a.jpg",
      "#{base}large_b.jpg"
    ] }] }

    assert_equal ["#{base}main_a.jpg", "#{base}large_b.jpg"], @client.send(:extract_image_urls, payload)
  end

  def test_embedded_json_selects_requested_post
    image = "https://c.fantia.jp/uploads/post_content_photo/file/42/main_a.jpg"
    data = { "posts" => [
      { "id" => 99, "post_contents" => [{ "images" => [image.sub("42", "99")] }] },
      { "id" => 42, "post_contents" => [{ "images" => [image] }] }
    ] }
    html = '<script type="application/json">' + JSON.generate(data) + "</script>"

    assert_equal [image], @client.send(
      :extract_image_urls_from_html,
      html,
      "https://fantia.jp/posts/42",
      post_id: "42"
    )
  end

  def test_extractor_reads_title_without_client
    extractor = FetchImages::Clients::Fantia::Extractor.new

    assert_equal "日本語の投稿", extractor.extract_page_title(
      '<meta property="og:title" content="日本語の投稿">'
    )
    assert_nil extractor.extract_authenticity_token("<html></html>")
  end

  def test_image_urls_collects_only_http_images_recursively
    collector = Class.new do
      include FetchImages::ImageUrls
    end.new
    image = "https://cdn.example.test/path/PHOTO.JPG?download=1"
    data = {
      "image" => image,
      "nested" => [image, "https://cdn.example.test/video.mp4", "not a URI"]
    }

    assert collector.looks_like_image_url?(image)
    refute collector.looks_like_image_url?("ftp://cdn.example.test/photo.jpg")
    assert_equal Set[image], collector.collect_image_urls(data)
  end

  def test_extractor_preserves_api_image_variant_selection
    base = "https://c.fantia.jp/uploads/post_content_photo/file/42/"
    payload = { "post_contents" => [{ "images" => [
      "#{base}small_a.jpg",
      "#{base}main_a.jpg",
      "#{base}large_b.jpg"
    ] }] }

    assert_equal @client.send(:extract_image_urls, payload), @extractor.extract_image_urls(payload)
  end

  def test_html_extraction_prefers_embedded_json
    expected = "https://c.fantia.jp/uploads/post_content_photo/file/42/main_json.jpg"
    data = { "id" => 42, "post_contents" => [{ "images" => [expected] }] }
    html = <<~HTML
      <script type="application/json">#{JSON.generate(data)}</script>
      <script>window.image = "https://c.fantia.jp/uploads/post_content_photo/file/42/main_script.jpg";</script>
      <div data-media="https://c.fantia.jp/uploads/post_content_photo/file/42/main_raw.jpg"></div>
      <img data-src="https:&#x2F;&#x2F;c.fantia.jp&#x2F;uploads&#x2F;post_content_photo&#x2F;file&#x2F;42&#x2F;main_element.jpg">
    HTML

    assert_html_extraction [expected], html
  end

  def test_html_extraction_uses_script_before_raw_and_elements
    expected = "https://c.fantia.jp/uploads/post_content_photo/file/42/main_script.jpg"
    html = <<~HTML
      <script>window.image = "https:\/\/c.fantia.jp\/uploads\/post_content_photo\/file\/42\/main_script.jpg";</script>
      <div data-media="https://c.fantia.jp/uploads/post_content_photo/file/42/main_raw.jpg"></div>
      <img data-src="https:&#x2F;&#x2F;c.fantia.jp&#x2F;uploads&#x2F;post_content_photo&#x2F;file&#x2F;42&#x2F;main_element.jpg">
    HTML

    assert_html_extraction [expected], html
  end

  def test_html_extraction_uses_raw_html_before_elements
    expected = "https://c.fantia.jp/uploads/post_content_photo/file/42/main_raw.jpg"
    html = <<~HTML
      <div data-media="https://c.fantia.jp/uploads/post_content_photo/file/42/main_raw.jpg"></div>
      <img data-src="https:&#x2F;&#x2F;c.fantia.jp&#x2F;uploads&#x2F;post_content_photo&#x2F;file&#x2F;42&#x2F;main_element.jpg">
    HTML

    assert_html_extraction [expected], html
  end

  def test_html_extraction_falls_back_to_elements
    expected = "https://c.fantia.jp/uploads/post_content_photo/file/42/main_element.jpg"
    html = <<~HTML
      <img data-src="https:&#x2F;&#x2F;c.fantia.jp&#x2F;uploads&#x2F;post_content_photo&#x2F;file&#x2F;42&#x2F;main_element.jpg">
    HTML

    assert_html_extraction [expected], html
  end

  private

  def assert_html_extraction(expected, html)
    client_result = @client.send(
      :extract_image_urls_from_html,
      html,
      "https://fantia.jp/posts/42",
      post_id: "42"
    )
    assert_equal expected, client_result
    assert_equal client_result, @extractor.extract_image_urls_from_html(
      html,
      "https://fantia.jp/posts/42",
      post_id: "42"
    )
  end
end
