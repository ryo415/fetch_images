# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "rbconfig"

class MyfansExtractorTest < Minitest::Test
  include ClientFixtures

  def test_browser_images_replace_html_candidates_before_filtering
    extractor = FetchImages::Clients::Myfans::Extractor.new

    result = extractor.select(
      { videos: [], images: ["https://media.example.test/html.jpg"] },
      fallback: {
        videos: [],
        images: [
          "https://media.example.test/browser.jpg",
          "https://media.example.test/thumb.jpg"
        ]
      }
    )

    assert_equal({ videos: [], images: ["https://media.example.test/browser.jpg"] }, result)
  end

  def test_collect_preserves_candidate_order_and_select_filters_at_the_end
    extractor = FetchImages::Clients::Myfans::Extractor.new
    payload = {
      "url" => "https://myfans.jp/posts/42",
      "html" => <<~HTML
        <meta property="og:video" content="https://media.example.test/first.mp4">
        <video src="https://myfans.jp/api/v1/posts/42/videos"></video>
        <video src="https://media.example.test/second.mp4"></video>
        <img src="https://media.example.test/first.jpg">
        <img src="https://media.example.test/second.jpg">
      HTML
    }

    candidates = extractor.collect(payload)

    assert_equal [
      "https://media.example.test/first.mp4",
      "https://myfans.jp/api/v1/posts/42/videos",
      "https://media.example.test/second.mp4"
    ], candidates[:videos]
    assert_equal [
      "https://media.example.test/first.jpg",
      "https://media.example.test/second.jpg"
    ], candidates[:images]
    assert_equal [
      "https://media.example.test/first.mp4",
      "https://media.example.test/second.mp4"
    ], extractor.select(candidates)[:videos]
  end

  def test_select_preserves_log_counts_for_raw_and_filtered_candidates
    messages = []
    extractor = FetchImages::Clients::Myfans::Extractor.new(logger: ->(message) { messages << message })

    extractor.select(
      {
        videos: ["https://myfans.jp/api/v1/posts/42/videos"],
        images: ["https://media.example.test/html.jpg"]
      },
      fallback: {
        videos: ["https://media.example.test/browser.mp4"],
        images: ["https://media.example.test/browser.jpg", "https://media.example.test/thumb.jpg"]
      }
    )

    assert_equal [
      "MyFans extraction: videos=2 filtered_videos=1 images=3 playwright_images=2 filtered_images=1"
    ], messages
  end

  def test_extract_post_body_text_removes_tag_lines_and_inline_tags
    doc = Nokogiri::HTML("<article>本文\n#tag\n続き #other</article>")

    assert_equal "本文 続き", FetchImages::Clients::Myfans::Extractor.new.extract_post_body_text(doc)
  end

  def test_collect_returns_empty_candidates_for_invalid_url
    result = FetchImages::Clients::Myfans::Extractor.new.collect(
      "url" => "https://myfans.jp/%",
      "html" => '<video src="https://media.example.test/post.mp4"></video>'
    )

    assert_equal({ videos: [], images: [] }, result)
  end

  def test_filtered_raw_video_candidate_uses_playwright_video
    payload = { "url" => "https://myfans.jp/posts/42", "html" =>
      '<video src="https://myfans.jp/api/v1/posts/42/videos"></video>' }
    client = client_with_payload(FetchImages::Clients::Myfans, payload, playwright: true)
    client.define_singleton_method(:fetch_media_urls_with_playwright) do |_|
      { videos: ["https://media.example.test/browser.m3u8"], images: [] }
    end

    assert_equal ["https://media.example.test/browser.m3u8"],
                 client.download_images(payload["url"], "/unused", dry_run: true).planned
  end

  def test_invalid_url_returns_before_playwright
    payload = { "url" => "https://myfans.jp/%", "html" => "" }
    client = client_with_payload(FetchImages::Clients::Myfans, payload, playwright: true)
    client.define_singleton_method(:fetch_media_urls_with_playwright) { |_| raise "must not run" }

    assert_empty client.download_images(payload["url"], "/unused", dry_run: true).planned
  end

  def test_html_image_is_used_when_no_video_is_found
    payload = { "url" => "https://myfans.jp/posts/42", "html" =>
      '<img src="https://media.example.test/post.jpg">' }
    client = client_with_payload(FetchImages::Clients::Myfans, payload)

    assert_equal ["https://media.example.test/post.jpg"],
                 client.download_images(payload["url"], "/unused", dry_run: true).planned
  end

  def test_extractor_can_be_required_before_client
    script = <<~'RUBY'
      require "fetch_images/clients/myfans/extractor"
      require "fetch_images/clients/myfans"
      abort "wrong Myfans superclass" unless FetchImages::Clients::Myfans.superclass == FetchImages::Client
      abort "extractor inherited Client" if FetchImages::Clients::Myfans::Extractor < FetchImages::Client
    RUBY

    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-I#{File.expand_path('../lib', __dir__)}",
      "-e",
      script
    )

    assert status.success?, stderr
  end
end
