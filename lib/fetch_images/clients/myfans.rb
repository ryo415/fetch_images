# frozen_string_literal: true

require "json"
require "nokogiri"
require "open3"
require "set"
require "tmpdir"
require "uri"
require_relative "../support"

module FetchImages
  module Clients
    class Myfans < Client
      URL_PATTERN = %r{\Ahttps?://(?:www\.)?myfans\.jp/}i.freeze
      VIDEO_URL_REGEX = %r{https?://[^"'\s)]+\.(?:mp4|webm|mov|m4v|m3u8)(?:\?[^"'\s)]*)?}i.freeze
      IMAGE_URL_REGEX = %r{https?://[^"'\s)]+\.(?:jpe?g|png|gif|bmp|webp|avif)(?:\?[^"'\s)]*)?}i.freeze
      PLAYWRIGHT_SCRIPT = File.expand_path("../../../scripts/myfans_media_playwright.mjs", __dir__).freeze

      def supports_url?(url)
        !!URL_PATTERN.match(url)
      end

      def initialize(session_id: nil, credentials: nil, cookie_header: nil, logger: nil, playwright: false, playwright_browser: nil)
        super(session_id: session_id, credentials: credentials, cookie_header: cookie_header, logger: logger)
        @playwright = playwright
        @playwright_browser = (playwright_browser || "chromium").to_s
      end

      def download_images(url, output_dir, overwrite: false, dry_run: false)
        post_id, payload = fetch_post_payload(url)
        media = extract_media_urls(payload)
        media_urls = if media[:videos].any?
                       media[:videos]
                     else
                       media[:images]
                     end
        result = DownloadResult.new(planned: media_urls.dup)
        return result if dry_run

        post_dir = File.join(output_dir, make_post_directory_name(post_id, payload))
        FileUtils.mkdir_p(post_dir)

        media_urls.each_with_index do |media_url, index|
          filename = build_filename(media_url, index + 1)
          target_path = File.join(post_dir, filename)
          if hls_url?(media_url)
            target_path = "#{File.join(post_dir, File.basename(target_path, ".*"))}.mp4"
          end
          if File.exist?(target_path) && !overwrite
            result.skipped << target_path
            next
          end

          headers = extra_download_headers(url, media_url)
          referer = download_referer(url, media_url)
          begin
            saved_path = if hls_url?(media_url)
                           download_hls_to_mp4(media_url, target_path, referer: referer, headers: headers)
                         else
                           download_file(media_url, target_path, referer: referer, headers: headers)
                         end
            result.downloaded << saved_path
          rescue StandardError => e
            log("MyFans download skip: #{media_url} (#{e.message})")
          end
        end

        result
      end

      private

      def session_cookie_name
        "myfans_session"
      end

      def fetch_post_payload(url)
        apply_cookies("myfans_session" => session_id) if session_id
        page = http_get(url, headers: { "Accept" => "text/html", "Referer" => url })
        [extract_post_id(url), { "url" => url, "html" => page.body }]
      end

      def extract_media_urls(payload)
        html = payload["html"].to_s
        url = payload["url"].to_s
        doc = Nokogiri::HTML(html)
        base_uri = URI.parse(url)
        video_urls = Set.new
        image_urls = Set.new

        extract_video_meta(doc).each { |candidate| add_media_url(video_urls, base_uri, candidate, type: :video, force: true) }
        extract_image_meta(doc).each { |candidate| add_media_url(image_urls, base_uri, candidate, type: :image) }
        extract_from_video_tags(doc).each { |candidate| add_media_url(video_urls, base_uri, candidate, type: :video, force: true) }
        extract_from_image_tags(doc).each { |candidate| add_media_url(image_urls, base_uri, candidate, type: :image) }
        extract_from_next_data(doc).each do |item|
          add_media_url(video_urls, base_uri, item[:url], type: :video) if item[:type] == :video
          add_media_url(image_urls, base_uri, item[:url], type: :image) if item[:type] == :image
        end
        extract_from_scripts(doc).each do |item|
          add_media_url(video_urls, base_uri, item[:url], type: :video) if item[:type] == :video
          add_media_url(image_urls, base_uri, item[:url], type: :image) if item[:type] == :image
        end

        if video_urls.empty? && @playwright
          fallback = fetch_media_urls_with_playwright(url)
          Array(fallback[:videos]).each { |u| video_urls << u }
          Array(fallback[:images]).each { |u| image_urls << u }
        end

        filtered_images = image_urls.to_a.reject { |u| thumbnail_like?(u) }
        filtered_videos = video_urls.to_a.select { |u| downloadable_video_url?(u) }
        log("MyFans extraction: videos=#{video_urls.size} filtered_videos=#{filtered_videos.size} images=#{image_urls.size} filtered_images=#{filtered_images.size}")
        { videos: filtered_videos, images: filtered_images }
      rescue URI::InvalidURIError
        { videos: [], images: [] }
      end

      def make_post_directory_name(post_id, payload)
        html = payload["html"].to_s
        doc = Nokogiri::HTML(html)
        body_text = extract_post_body_text(doc)
        sanitize_directory_name(body_text, fallback: post_id.to_s.empty? ? "post" : post_id.to_s)
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

      def extract_post_id(url)
        uri = URI.parse(url)
        segments = uri.path.to_s.split("/").reject(&:empty?)
        segments.last.to_s.empty? ? "post" : segments.last
      rescue URI::InvalidURIError
        "post"
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

        # Some pages expose signed video endpoints without extension.
        content_param = uri.query.to_s.downcase
        return true if content_param.match?(/(?:mp4|m3u8|hls|stream|playback|manifest|playlist|mime=video|content[_-]?type=video)/)

        host = uri.host.to_s.downcase
        host.include?("video")
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

      def hls_url?(url)
        uri = URI.parse(url)
        path = uri.path.to_s.downcase
        path.end_with?(".m3u8") || uri.query.to_s.downcase.include?("m3u8")
      rescue URI::InvalidURIError
        false
      end

      def download_hls_to_mp4(url, path, referer:, headers:)
        ffmpeg_bin = resolve_ffmpeg_binary
        raise "ffmpeg not found (install ffmpeg to save MyFans HLS as mp4)" unless ffmpeg_bin

        header_map = {
          "User-Agent" => USER_AGENT,
          "Referer" => referer,
          "Cookie" => build_cookie_header
        }.merge(headers || {})
        header_text = header_map.each_with_object(+"") do |(key, value), memo|
          next if value.to_s.empty?

          memo << "#{key}: #{value}\r\n"
        end

        tmp_path = "#{path}.tmp.mp4"
        command = [
          ffmpeg_bin,
          "-y",
          "-loglevel", "error",
          "-headers", header_text,
          "-i", url,
          "-c", "copy",
          "-bsf:a", "aac_adtstoasc",
          tmp_path
        ]
        log("MyFans ffmpeg: #{ffmpeg_bin} -i #{url} -> #{path}")
        stdout, stderr, status = Open3.capture3(*command)
        unless status.success?
          message = stderr.to_s.strip
          message = stdout.to_s.strip if message.empty?
          message = "unknown error" if message.empty?
          raise "ffmpeg failed: #{message}"
        end

        FileUtils.mv(tmp_path, path)
        path
      ensure
        File.delete(tmp_path) if defined?(tmp_path) && tmp_path && File.exist?(tmp_path)
      end

      def fetch_media_urls_with_playwright(url)
        unless File.exist?(PLAYWRIGHT_SCRIPT)
          log("MyFans Playwright: script not found at #{PLAYWRIGHT_SCRIPT}")
          return { videos: [], images: [] }
        end
        node_bin = resolve_node_binary
        unless node_bin
          log("MyFans Playwright: node executable not found (set NODE_BIN if needed)")
          return { videos: [], images: [] }
        end

        output_path = File.join(Dir.tmpdir, "myfans_media_#{Time.now.to_i}_#{$PROCESS_ID}.json")
        command = [
          node_bin,
          PLAYWRIGHT_SCRIPT,
          "--url", url,
          "--output", output_path,
          "--browser", @playwright_browser
        ]
        env = {}
        cookie_header = build_cookie_header
        env["MYFANS_COOKIE_HEADER"] = cookie_header unless cookie_header.empty?

        log("MyFans Playwright: trying fallback (browser=#{@playwright_browser})")
        stdout, stderr, status = Open3.capture3(env, *command)
        log("MyFans Playwright stdout: #{stdout.strip}") unless stdout.to_s.strip.empty?
        log("MyFans Playwright stderr: #{stderr.strip}") unless stderr.to_s.strip.empty?
        unless status.success?
          log("MyFans Playwright: fallback failed with exit=#{status.exitstatus}")
          return { videos: [], images: [] }
        end

        parsed = JSON.parse(File.read(output_path))
        {
          videos: Array(parsed["videos"]),
          images: Array(parsed["images"])
        }
      rescue StandardError => e
        log("MyFans Playwright: fallback error (#{e.message})")
        { videos: [], images: [] }
      ensure
        File.delete(output_path) if output_path && File.exist?(output_path)
      end

      def resolve_node_binary
        Support.resolve_executable("node", "nodejs", env_key: "NODE_BIN")
      end

      def resolve_ffmpeg_binary
        Support.resolve_executable("ffmpeg", env_key: "FFMPEG_BIN")
      end
    end
  end
end
