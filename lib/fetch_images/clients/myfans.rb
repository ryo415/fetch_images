# frozen_string_literal: true

require "nokogiri"
require "uri"
require_relative "../playwright_runner"
require_relative "../support"

module FetchImages
  module Clients
    class Myfans < Client
      URL_PATTERN = %r{\Ahttps?://(?:www\.)?myfans\.jp/}i.freeze
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
        url = payload["url"].to_s
        URI.parse(url)
        candidates = extractor.collect(payload)
        fallback = if candidates[:videos].empty? && @playwright
                     fetch_media_urls_with_playwright(url)
                   else
                     { videos: [], images: [] }
                   end
        extractor.select(candidates, fallback: fallback)
      rescue URI::InvalidURIError
        { videos: [], images: [] }
      end

      def make_post_directory_name(post_id, payload)
        html = payload["html"].to_s
        doc = Nokogiri::HTML(html)
        body_text = extractor.extract_post_body_text(doc)
        sanitize_directory_name(body_text, fallback: post_id.to_s.empty? ? "post" : post_id.to_s)
      end

      def extract_post_id(url)
        uri = URI.parse(url)
        segments = uri.path.to_s.split("/").reject(&:empty?)
        segments.last.to_s.empty? ? "post" : segments.last
      rescue URI::InvalidURIError
        "post"
      end


      def extractor
        @extractor ||= Extractor.new(logger: @logger)
      end

      def hls_url?(url)
        uri = URI.parse(url)
        path = uri.path.to_s.downcase
        path.end_with?(".m3u8") || uri.query.to_s.downcase.include?("m3u8")
      rescue URI::InvalidURIError
        false
      end

      def download_hls_to_mp4(url, path, referer:, headers:)
        header_map = {
          "User-Agent" => USER_AGENT,
          "Referer" => referer,
          "Cookie" => build_cookie_header
        }.merge(headers || {})
        HlsDownloader.new(logger: @logger).download(
          url, path, executable: resolve_ffmpeg_binary, headers: header_map
        )
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

        args = [
          "--url", url,
          "--browser", @playwright_browser
        ]
        env = {}
        cookie_header = build_cookie_header
        env["MYFANS_COOKIE_HEADER"] = cookie_header unless cookie_header.empty?

        log("MyFans Playwright: trying fallback (browser=#{@playwright_browser})")
        status = nil
        parsed = PlaywrightRunner.new.run(node: node_bin, script: PLAYWRIGHT_SCRIPT, args: args, env: env) do |stdout, stderr, process_status|
          status = process_status
          log("MyFans Playwright stdout: #{stdout.strip}") unless stdout.to_s.strip.empty?
          log("MyFans Playwright stderr: #{stderr.strip}") unless stderr.to_s.strip.empty?
          log("MyFans Playwright: fallback failed with exit=#{status.exitstatus}") unless status.success?
        end
        return { videos: [], images: [] } unless status.success?

        {
          videos: Array(parsed["videos"]),
          images: Array(parsed["images"])
        }
      rescue StandardError => e
        log("MyFans Playwright: fallback error (#{e.message})")
        { videos: [], images: [] }
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

require_relative "myfans/extractor"
require_relative "myfans/hls_downloader"
