# frozen_string_literal: true

require "json"
require "uri"

module FetchImages
  module Clients
    class Fanbox < Client
      URL_PATTERN = %r{
        \Ahttps?://
        (?:(?<creator>[a-zA-Z0-9_-]+)\.fanbox\.cc|www\.fanbox\.cc/@(?<creator>[a-zA-Z0-9_-]+))
        /posts/(?<id>\d+)
      }x.freeze
      API_URL = "https://api.fanbox.cc/post.info".freeze

      def supports_url?(url)
        !!URL_PATTERN.match(url)
      end

      private

      def session_cookie_name
        "FANBOXSESSID"
      end

      def fetch_post_payload(url)
        match = URL_PATTERN.match(url)
        raise UnsupportedUrlError, url unless match

        post_id = match[:id]
        creator = match[:creator]
        uri = URI.parse(url)
        origin = "#{uri.scheme}://www.fanbox.cc"
        referer = "#{origin}/@#{creator}/posts/#{post_id}"
        headers = {
          "Accept" => "application/json, text/plain, */*",
          "Referer" => referer,
          "Origin" => origin
        }
        apply_cookies("FANBOXSESSID" => session_id) if session_id

        response = http_get(API_URL, headers: headers, params: { "postId" => post_id })
        data = JSON.parse(response.body)
        [post_id, data]
      end

      def extract_image_urls(payload)
        urls = Set.new
        body = payload["body"]
        urls.merge(collect_image_urls(body)) if body.is_a?(Hash) || body.is_a?(Array)

        cover = payload["coverImageUrl"]
        urls << cover if cover.is_a?(String) && looks_like_image_url?(cover)

        image_map = payload["imageMap"]
        urls.merge(collect_image_urls(image_map)) if image_map

        urls.merge(collect_image_urls(payload)) if urls.empty?
        urls.to_a
      end

      def make_post_directory_name(post_id, payload)
        creator = payload["creatorId"] || payload.dig("user", "userId") || "fanbox"
        title = payload["title"] || payload.dig("body", "title") || "post"
        creator_slug = slugify(creator)
        title_slug = slugify(title)
        ["fanbox", creator_slug, post_id, title_slug].reject(&:empty?).join("_")
      end
    end
  end
end
