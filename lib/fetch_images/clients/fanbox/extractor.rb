# frozen_string_literal: true

require "json"
require "nokogiri"
require "uri"
require_relative "../../image_urls"
require_relative "../../support"

module FetchImages
  module Clients
    class Fanbox
      class Extractor
        include ImageUrls

        def initialize(logger: nil)
          @logger = logger
        end

        def extract_image_urls(payload)
          urls = Set.new
          post_body = payload["body"].is_a?(Hash) ? payload["body"] : payload
          post_content = post_body["body"]

          if post_content.is_a?(Hash) && post_content["images"].is_a?(Array)
            post_content["images"].each do |image|
              next unless image.is_a?(Hash)

              original = image["originalUrl"]
              urls << original if original.is_a?(String) && looks_like_image_url?(original)
            end
          end

          # Some post types (file/article) expose image URLs in map-style fields.
          image_map = post_body["imageMap"] || post_content&.[]("imageMap")
          if urls.empty? && image_map
            collect_image_urls(image_map).each do |url|
              urls << url if fanbox_post_image_url?(url)
            end
          end

          if urls.empty? && post_content
            collect_image_urls(post_content).each do |url|
              urls << url if fanbox_post_image_url?(url)
            end
          end

          # Last resort: allow direct cover image when no post body image is found.
          if urls.empty?
            cover = post_body["coverImageUrl"] || payload["coverImageUrl"]
            urls << cover if cover.is_a?(String) && looks_like_image_url?(cover)
          end

          filtered = urls.reject { |url| fanbox_non_post_image_url?(url) }.to_a
          filtered
        end

        def extract_page_title(html)
          doc = Nokogiri::HTML(html)
          doc.at_css("meta[property='og:title']")&.[]("content") ||
            doc.at_css("title")&.text&.strip ||
            "post"
        end

        def extract_image_urls_from_html(html, base_url, post_id:)
          doc = Nokogiri::HTML(html)
          urls = Set.new

          next_data = doc.at_css("script#__NEXT_DATA__")&.text.to_s
          unless next_data.empty?
            begin
              parsed = JSON.parse(next_data)
              collect_image_urls(parsed).each do |candidate|
                urls << candidate if likely_fanbox_image_url?(candidate, post_id)
              end
            rescue JSON::ParserError
              # fall through to raw scan
            end
          end

          if urls.empty?
            doc.css("script").each do |script|
              text = Support.normalize_escaped_text(script.text.to_s)
              text.scan(%r{https?://[^"'\s)]+?/fanbox/public/images/post/[^"'\s)]+}i) do |match|
                urls << match if likely_fanbox_image_url?(match, post_id)
              end
            end
          end

          if urls.empty?
            normalized = Support.normalize_escaped_text(html.to_s)
            normalized.scan(%r{https?://[^"'\s)]+?/fanbox/public/images/[^"'\s)]+}i) do |match|
              urls << match if likely_fanbox_image_url?(match, post_id)
            end
          end

          if urls.empty?
            broad_candidates = collect_broad_image_candidates(html)
            log("Fanbox post=#{post_id}: broad HTML candidate count=#{broad_candidates.size}")
            broad_candidates.each do |candidate|
              urls << candidate if likely_fanbox_image_url_relaxed?(candidate)
            end
          end

          log("Fanbox post=#{post_id}: HTML fallback extracted #{urls.size} URL(s)")
          urls.to_a
        end

        def extract_csrf_token_from_metadata(html)
          doc = Nokogiri::HTML(Support.safe_utf8(html))
          raw = doc.at_css("meta#metadata")&.[]("content").to_s
          return nil if raw.empty?

          parsed = JSON.parse(raw)
          parsed["csrfToken"]
        rescue JSON::ParserError
          nil
        end

        def extract_metadata_user_flags(html)
          doc = Nokogiri::HTML(html)
          raw = doc.at_css("meta#metadata")&.[]("content").to_s
          return { is_logged_in: nil, is_supporter: nil } if raw.empty?

          parsed = JSON.parse(raw)
          user = parsed.dig("context", "user") || {}
          {
            is_logged_in: !parsed.dig("urlContext", "user").nil?,
            is_supporter: user["isSupporter"]
          }
        rescue StandardError
          { is_logged_in: nil, is_supporter: nil }
        end

        private

        def log(message)
          @logger&.call(message)
        end

        def likely_fanbox_image_url?(url, post_id)
          uri = URI(url)
          return false unless uri.is_a?(URI::HTTP)

          host = uri.host.to_s.downcase
          path = uri.path.to_s.downcase
          return false unless host.include?("pximg") || host.include?("fanbox")

          # Prefer post body assets and avoid logos/covers/common assets.
          return false unless path.include?("/fanbox/public/images/post/")
          return false if path.include?("/common/") || path.include?("/logo") || path.include?("/cover/")

          true
        rescue URI::InvalidURIError
          false
        end

        def likely_fanbox_image_url_relaxed?(url)
          uri = URI(url)
          return false unless uri.is_a?(URI::HTTP)

          host = uri.host.to_s.downcase
          path = uri.path.to_s.downcase
          return false unless host.include?("pximg") || host.include?("fanbox")
          return false unless path.include?("/fanbox/public/images/")
          return false if path.include?("/common/") || path.include?("/logo")
          return false if path.include?("/cover/") || path.include?("/creator/")

          true
        rescue URI::InvalidURIError
          false
        end

        def fanbox_post_image_url?(url)
          uri = URI(url)
          return false unless uri.is_a?(URI::HTTP)

          path = uri.path.to_s.downcase
          return false unless path.include?("/fanbox/public/images/") || path.include?("/images/post/")

          !fanbox_non_post_image_url?(url)
        rescue URI::InvalidURIError
          false
        end

        def fanbox_non_post_image_url?(url)
          uri = URI(url)
          path = uri.path.to_s.downcase
          path.include?("/icon/") ||
            path.include?("/creator/") ||
            path.include?("/cover/") ||
            path.include?("/common/") ||
            path.include?("imageforshare")
        rescue URI::InvalidURIError
          false
        end

        def collect_broad_image_candidates(html)
          normalized = Support.normalize_escaped_text(html.to_s)
          candidates = Set.new
          normalized.scan(%r{https?://[^"'\s)]+}i) do |url|
            next unless url.include?("fanbox/public/images/")

            candidates << url
          end
          candidates
        end
      end
    end
  end
end
