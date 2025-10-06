# frozen_string_literal: true

require "json"
require "uri"

module FetchImages
  module Clients
    class Fantia < Client
      URL_PATTERN = %r{https?://(?:www\.)?fantia\.jp/(?:fanclubs/\d+/)?posts/(?<id>\d+)}.freeze
      API_URL_TEMPLATE = "https://fantia.jp/api/v1/posts/%{post_id}".freeze

      def supports_url?(url)
        !!URL_PATTERN.match(url)
      end

      private

      def fetch_post_payload(url)
        match = URL_PATTERN.match(url)
        raise UnsupportedUrlError, url unless match

        post_id = match[:id]
        api_url = format(API_URL_TEMPLATE, post_id: post_id)
        headers = {
          "Accept" => "application/json",
          "Referer" => url
        }
        apply_cookies("_session_id" => session_id) if session_id

        response = http_get(api_url, headers: headers)
        data = JSON.parse(response.body)
        post = data["post"] || data
        [post_id, post]
      end

      def extract_image_urls(payload)
        urls = Set.new
        %w[thumb cover_image_url cover_image].each do |key|
          value = payload[key]
          urls << value if value.is_a?(String) && looks_like_image_url?(value)
        end

        Array(payload["post_contents"]).each do |content|
          urls.merge(collect_image_urls(content))
        end
        Array(payload["post_attachments"]).each do |attachment|
          urls.merge(collect_image_urls(attachment))
        end

        urls.merge(collect_image_urls(payload)) if urls.empty?
        urls.to_a
      end

      def make_post_directory_name(post_id, payload)
        title = payload["title"] || "post"
        fanclub = payload["fanclub"] || {}
        creator = fanclub["fanclub_name"] || fanclub["name"] || fanclub["creator_name"] || fanclub["id"] || "fantia"
        creator_slug = slugify(creator)
        title_slug = slugify(title)
        ["fantia", creator_slug, post_id, title_slug].reject(&:empty?).join("_")
      end
    end
  end
end
