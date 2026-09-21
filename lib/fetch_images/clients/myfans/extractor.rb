# frozen_string_literal: true

require "json"
require "nokogiri"
require "set"
require "uri"
require_relative "../../client"
require_relative "../../support"

module FetchImages
  module Clients
    class Myfans < Client
      class Extractor
        include ImageUrls

        VIDEO_URL_REGEX = %r{https?://[^"'\s)]+\.(?:mp4|webm|mov|m4v|m3u8)(?:\?[^"'\s)]*)?}i.freeze
        IMAGE_URL_REGEX = %r{https?://[^"'\s)]+\.(?:jpe?g|png|gif|bmp|webp|avif)(?:\?[^"'\s)]*)?}i.freeze

        def initialize(logger: nil)
          @logger = logger
        end

        def collect(payload)
          doc = Nokogiri::HTML(payload["html"].to_s)
          base_uri = URI.parse(payload["url"].to_s)
          video_urls = Set.new
          image_urls = Set.new

          extract_video_meta(doc).each do |candidate|
            add_media_url(video_urls, base_uri, candidate, type: :video, force: true)
          end
          extract_image_meta(doc).each do |candidate|
            add_media_url(image_urls, base_uri, candidate, type: :image)
          end
          extract_from_video_tags(doc).each do |candidate|
            add_media_url(video_urls, base_uri, candidate, type: :video, force: true)
          end
          extract_from_image_tags(doc).each do |candidate|
            add_media_url(image_urls, base_uri, candidate, type: :image)
          end
          extract_from_next_data(doc).each do |item|
            add_media_url(video_urls, base_uri, item[:url], type: :video) if item[:type] == :video
            add_media_url(image_urls, base_uri, item[:url], type: :image) if item[:type] == :image
          end
          extract_from_scripts(doc).each do |item|
            add_media_url(video_urls, base_uri, item[:url], type: :video) if item[:type] == :video
            add_media_url(image_urls, base_uri, item[:url], type: :image) if item[:type] == :image
          end

          { videos: video_urls.to_a, images: image_urls.to_a }
        rescue URI::InvalidURIError
          { videos: [], images: [] }
        end

        def select(candidates, fallback: { videos: [], images: [] })
          video_urls = Set.new(Array(candidates[:videos]))
          image_urls = Set.new(Array(candidates[:images]))
          fallback_videos = Array(fallback[:videos])
          fallback_images = Array(fallback[:images])

          fallback_videos.each { |url| video_urls << url }
          fallback_images.each { |url| image_urls << url }

          image_candidates = fallback_images.any? ? fallback_images : image_urls.to_a
          filtered_images = image_candidates.reject { |url| non_post_image_url?(url) }
          filtered_videos = video_urls.select { |url| downloadable_video_url?(url) }.to_a
          log(
            "MyFans extraction: videos=#{video_urls.size} filtered_videos=#{filtered_videos.size} " \
            "images=#{image_urls.size} playwright_images=#{fallback_images.size} filtered_images=#{filtered_images.size}"
          )
          { videos: filtered_videos, images: filtered_images }
        end

        def extract_post_body_text(doc)
          candidates = []
          candidates << doc.at_css("meta[property='og:description']")&.[]("content")
          candidates << doc.at_css("meta[name='description']")&.[]("content")
          candidates.concat(extract_body_text_candidates(doc))

          cleaned = candidates.filter_map do |candidate|
            text = clean_post_body_text(candidate)
            next if text.empty?

            text
          end

          cleaned.max_by(&:length) || "post"
        end

        private

        def extract_body_text_candidates(doc)
          selectors = [
            "article",
            "main",
            "[class*='post']",
            "[class*='content']",
            "[class*='body']",
            "[class*='description']",
            "[data-testid*='post']",
            "[data-testid*='content']"
          ]

          selectors.flat_map do |selector|
            doc.css(selector).map(&:text)
          end
        end

        def clean_post_body_text(text)
          normalized = text.to_s
          normalized = normalized.unicode_normalize(:nfkc) if normalized.respond_to?(:unicode_normalize)
          normalized = normalized.gsub(/\r\n?/, "\n")
          normalized = normalized.lines.filter_map do |line|
            stripped = line.strip
            next if stripped.empty?
            next if stripped.match?(/\A(?:#\S+\s*)+\z/)

            stripped.gsub(/(^|\s)#\S+/, " ").strip
          end.join(" ")
          normalized.gsub(/\s+/, " ").strip
        end

        def extract_creator_from_url(url)
          uri = URI.parse(url)
          segments = uri.path.to_s.split("/").reject(&:empty?)
          return nil if segments.empty?

          first = segments.first
          %w[posts post video videos contents].include?(first) ? nil : first
        rescue URI::InvalidURIError
          nil
        end

        def extract_video_meta(doc)
          keys = [
            "meta[property='og:video']",
            "meta[property='og:video:url']",
            "meta[property='og:video:secure_url']",
            "meta[name='twitter:player:stream']"
          ]
          keys.filter_map { |selector| doc.at_css(selector)&.[]("content") }
        end

        def extract_image_meta(doc)
          keys = [
            "meta[property='og:image']",
            "meta[property='og:image:url']",
            "meta[property='og:image:secure_url']",
            "meta[name='twitter:image']"
          ]
          keys.filter_map { |selector| doc.at_css(selector)&.[]("content") }
        end

        def extract_from_video_tags(doc)
          urls = []
          doc.css("video, source").each do |node|
            %w[src data-src data-video-src].each do |attr|
              value = node[attr]
              urls << value unless value.to_s.strip.empty?
            end
          end
          urls
        end

        def extract_from_image_tags(doc)
          urls = []
          doc.css("img").each do |node|
            %w[src data-src data-original data-lazy-src].each do |attr|
              value = node[attr]
              urls << value unless value.to_s.strip.empty?
            end

            %w[srcset data-srcset].each do |attr|
              srcset = node[attr]
              next if srcset.to_s.strip.empty?

              srcset.split(",").each do |entry|
                candidate = entry.strip.split(/\s+/, 2).first
                urls << candidate unless candidate.to_s.strip.empty?
              end
            end
          end
          urls
        end

        def extract_from_next_data(doc)
          script = doc.at_css("script#__NEXT_DATA__")
          return [] unless script

          parsed = JSON.parse(script.text.to_s)
          collect_media_urls(parsed).to_a
        rescue JSON::ParserError
          []
        end

        def extract_from_scripts(doc)
          urls = Set.new
          doc.css("script").each do |script|
            text = Support.normalize_escaped_text(script.text.to_s)
            text.scan(VIDEO_URL_REGEX) { |match| urls << { type: :video, url: match } }
            text.scan(IMAGE_URL_REGEX) { |match| urls << { type: :image, url: match } }
            text.scan(/(?:video|movie|stream|playback|manifest|playlist|hls|source|src)\s*[:=]\s*["'](https?:\/\/[^"']+)["']/i) do |match|
              urls << { type: :video, url: match.first }
            end
            text.scan(%r{https?://[^"'\s)]+}i) do |match|
              if likely_video_url?(match)
                urls << { type: :video, url: match }
              elsif looks_like_image_url?(match)
                urls << { type: :image, url: match }
              end
            end
          end
          urls.to_a
        end

        def collect_media_urls(data, urls = Set.new)
          case data
          when Hash
            data.each_value { |value| collect_media_urls(value, urls) }
          when Array
            data.each { |value| collect_media_urls(value, urls) }
          when String
            if likely_video_url?(data)
              urls << { type: :video, url: data }
            elsif looks_like_image_url?(data)
              urls << { type: :image, url: data }
            end
          end
          urls
        end

        def add_media_url(urls, base_uri, candidate, type:, force: false)
          return if candidate.to_s.strip.empty?

          absolute = URI.join(base_uri, candidate).to_s
          if force
            urls << absolute
            return
          end

          case type
          when :video
            urls << absolute if likely_video_url?(absolute)
          when :image
            urls << absolute if looks_like_image_url?(absolute)
          end
        rescue URI::InvalidURIError
          nil
        end

        def likely_video_url?(url)
          uri = URI.parse(url)
          return false unless uri.is_a?(URI::HTTP)

          path = uri.path.to_s.downcase
          return false if IMAGE_EXTENSIONS.include?(File.extname(path))
          return false if path.end_with?(".ts", ".m4s", ".aac", ".vtt")
          return false if path.start_with?("/api/")
          return true if path.end_with?(".mp4", ".webm", ".mov", ".m4v", ".m3u8")
          return true if path.match?(%r{/(?:video|videos|movie|movies|stream|playback|manifest|playlist|hls|dash|vod)(?:/|$)})

          content_param = uri.query.to_s.downcase
          return true if content_param.match?(/(?:mp4|m3u8|hls|stream|playback|manifest|playlist|mime=video|content[_-]?type=video)/)

          uri.host.to_s.downcase.include?("video")
        rescue URI::InvalidURIError
          false
        end

        def downloadable_video_url?(url)
          return false unless likely_video_url?(url)

          uri = URI.parse(url)
          path = uri.path.to_s.downcase
          return false if path.start_with?("/api/")
          return false if path.match?(%r{/api/v\d+/posts/[^/]+/videos/?\z})
          return false if path.end_with?(".ts", ".m4s", ".aac", ".vtt")

          true
        rescue URI::InvalidURIError
          false
        end

        def thumbnail_like?(url)
          path = URI.parse(url).path.to_s.downcase
          path.include?("thumb") ||
            path.include?("thumbnail") ||
            path.include?("preview") ||
            path.include?("poster") ||
            path.include?("small")
        rescue URI::InvalidURIError
          false
        end

        def non_post_image_url?(url)
          uri = URI.parse(url)
          path = uri.path.to_s.downcase
          basename = File.basename(path)
          thumbnail_like?(url) ||
            basename == "c.gif" ||
            path.match?(%r{/(?:collect|analytics|tracking|beacon|pixel)(?:/|$)})
        rescue URI::InvalidURIError
          true
        end

        def log(message)
          @logger&.call(message)
        end
      end
    end
  end
end
