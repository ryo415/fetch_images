# frozen_string_literal: true

require "json"
require "nokogiri"
require "open3"
require "tmpdir"
require "uri"
require_relative "../support"

module FetchImages
  module Clients
    class Fanbox < Client
      URL_PATTERN = %r{
        \Ahttps?://
        (?:(?<creator>[a-zA-Z0-9_-]+)\.fanbox\.cc|www\.fanbox\.cc/@(?<creator>[a-zA-Z0-9_-]+))
        /posts/(?<id>\d+)
      }x.freeze
      API_URL = "https://api.fanbox.cc/post.info".freeze
      BROWSER_USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "\
        "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36".freeze
      PLAYWRIGHT_SCRIPT = File.expand_path("../../../scripts/fanbox_post_info_playwright.mjs", __dir__).freeze

      def supports_url?(url)
        !!URL_PATTERN.match(url)
      end

      def initialize(session_id: nil, credentials: nil, cookie_header: nil, logger: nil, playwright: false, playwright_browser: nil, post_info_json_path: nil)
        super(session_id: session_id, credentials: credentials, cookie_header: cookie_header, logger: logger)
        @playwright = playwright
        @playwright_browser = (playwright_browser || "chromium").to_s
        @post_info_json_path = post_info_json_path
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

        manual_payload = load_manual_post_info_payload(post_id)
        return [post_id, manual_payload] if manual_payload

        uri = URI.parse(url)
        origin_host = uri.host == "www.fanbox.cc" ? "www.fanbox.cc" : "#{creator}.fanbox.cc"
        origin = "#{uri.scheme}://#{origin_host}"
        canonical_www_post_url = "https://www.fanbox.cc/@#{creator}/posts/#{post_id}"
        page = http_get(url, headers: { "Accept" => "text/html", "Referer" => url })
        log("Fanbox post=#{post_id}: fetched post page for fallback")
        log_page_visibility(post_id, page.body, creator)
        csrf_token = extract_csrf_token_from_metadata(page.body)
        log("Fanbox post=#{post_id}: csrf_token_present=#{!csrf_token.to_s.empty?}")
        apply_cookies("FANBOXSESSID" => session_id) if session_id

        api_errors = []
        api_attempts = [
          { api_url: API_URL, referer: url, origin: origin, fetch_site: "same-site" },
          { api_url: API_URL, referer: canonical_www_post_url, origin: "https://www.fanbox.cc", fetch_site: "same-site" },
          { api_url: API_URL, referer: canonical_www_post_url, origin: "https://www.fanbox.cc", fetch_site: "cross-site" },
          { api_url: API_URL, referer: "https://www.fanbox.cc/", origin: "https://www.fanbox.cc", fetch_site: "same-site" },
          { api_url: "#{origin}/api/post.info", referer: url, origin: origin, fetch_site: "same-origin" }
        ]

        api_attempts.each do |attempt|
          headers = build_api_headers(
            referer: attempt[:referer],
            origin: attempt[:origin],
            fetch_site: attempt[:fetch_site],
            csrf_token: csrf_token
          )
          api_url = attempt[:api_url]
          begin
            log("Fanbox post=#{post_id}: trying API #{api_url} (referer=#{attempt[:referer]}, origin=#{attempt[:origin]}, fetch_site=#{attempt[:fetch_site]})")
            response = http_get(api_url, headers: headers, params: { "postId" => post_id })
            data = JSON.parse(response.body)
            log("Fanbox post=#{post_id}: API payload loaded from #{api_url}")
            return [post_id, data]
          rescue StandardError => e
            api_errors << "#{api_url} (referer=#{attempt[:referer]}, origin=#{attempt[:origin]}): #{e.message}"
            raise unless fallback_candidate_error?(e)
          end
        end

        if @playwright
          playwright_payload = fetch_post_payload_with_playwright(url, post_id)
          return [post_id, playwright_payload] if playwright_payload
        end

        log("Fanbox post=#{post_id}: API failed (#{api_errors.join(' | ')}), fallback to HTML parse")
        image_urls = extract_image_urls_from_html(page.body, url, post_id: post_id)
        write_debug_html_snapshot(post_id, page.body) if image_urls.empty?
        fallback_payload = {
          "title" => extract_page_title(page.body),
          "body" => { "images" => image_urls }
        }
        [post_id, fallback_payload]
      end

      def build_api_headers(referer:, origin:, fetch_site:, csrf_token: nil)
        headers = {
          "Accept" => "application/json, text/plain, */*",
          "Referer" => referer,
          "Origin" => origin,
          "User-Agent" => BROWSER_USER_AGENT,
          "Accept-Language" => "ja,en-US;q=0.9,en;q=0.8",
          "X-Requested-With" => "XMLHttpRequest",
          "Sec-Fetch-Site" => fetch_site,
          "Sec-Fetch-Mode" => "cors",
          "Sec-Fetch-Dest" => "empty"
        }
        headers["X-CSRF-Token"] = csrf_token unless csrf_token.to_s.empty?
        headers
      end

      def extract_image_urls(payload)
        extractor.extract_image_urls(payload)
      end

      def make_post_directory_name(post_id, payload)
        title = payload["title"] || payload.dig("body", "title") || "post"
        sanitize_directory_name(title, fallback: post_id.to_s.empty? ? "post" : post_id.to_s)
      end

      def extra_download_headers(page_url, image_url)
        page_uri = URI.parse(page_url)
        image_uri = URI.parse(image_url)
        fetch_site = page_uri.host == image_uri.host ? "same-origin" : "cross-site"
        {
          "User-Agent" => BROWSER_USER_AGENT,
          "Accept" => "image/avif,image/webp,image/apng,image/*,*/*;q=0.8",
          "Accept-Language" => "ja,en-US;q=0.9,en;q=0.8",
          "Origin" => "#{page_uri.scheme}://#{page_uri.host}",
          "Sec-Fetch-Site" => fetch_site,
          "Sec-Fetch-Mode" => "no-cors",
          "Sec-Fetch-Dest" => "image"
        }
      rescue URI::InvalidURIError
        {
          "User-Agent" => BROWSER_USER_AGENT,
          "Accept" => "image/avif,image/webp,image/apng,image/*,*/*;q=0.8"
        }
      end

      def download_referer(page_url, image_url)
        image_uri = URI.parse(image_url)
        # downloads.fanbox.cc/pixiv CDN links are often signed and can fail with strict referer checks.
        return nil if image_uri.host.to_s.include?("downloads.fanbox.cc") || image_uri.host.to_s.include?("pximg.net")

        page_url
      rescue URI::InvalidURIError
        page_url
      end

      def fallback_candidate_error?(error)
        message = error.message.to_s
        return false unless message.include?("HTTP request failed with status")

        status = message[/status\s+(\d{3})/, 1]&.to_i
        return true if status.nil?

        [401, 403, 404, 410, 422, 429].include?(status)
      end

      def extract_page_title(html)
        extractor.extract_page_title(html)
      end

      def extract_image_urls_from_html(html, base_url, post_id:)
        extractor.extract_image_urls_from_html(html, base_url, post_id: post_id)
      end

      def log_page_visibility(post_id, html, creator)
        body = Support.safe_utf8(html)
        has_next_data = body.include?("__NEXT_DATA__")
        has_post_asset = body.include?("/fanbox/public/images/post/")
        has_login_hint = body.match?(/login|ログイン/i)
        has_fanboxsessid_marker = body.include?("FANBOXSESSID")
        generic_title = extract_page_title(body) == "pixivFANBOX"
        creator_marker = body.include?("@#{creator}") || body.include?("#{creator}.fanbox.cc")
        metadata_flags = extract_metadata_user_flags(body)

        log(
          "Fanbox post=#{post_id}: page visibility " \
          "next_data=#{has_next_data} post_asset_hint=#{has_post_asset} " \
          "login_hint=#{has_login_hint} generic_title=#{generic_title} " \
          "creator_marker=#{creator_marker} fanboxsessid_marker=#{has_fanboxsessid_marker} " \
          "metadata_is_logged_in=#{metadata_flags[:is_logged_in]} metadata_is_supporter=#{metadata_flags[:is_supporter]}"
        )
      end

      def extract_csrf_token_from_metadata(html)
        extractor.extract_csrf_token_from_metadata(html)
      end

      def write_debug_html_snapshot(post_id, html)
        path = File.join(Dir.tmpdir, "fanbox_post_#{post_id}_debug.html")
        File.write(path, Support.safe_utf8(html))
        log("Fanbox post=#{post_id}: wrote debug HTML snapshot to #{path}")
      rescue StandardError => e
        log("Fanbox post=#{post_id}: failed to write debug HTML snapshot (#{e.message})")
      end

      def extract_metadata_user_flags(html)
        extractor.extract_metadata_user_flags(html)
      end

      def extractor
        @extractor ||= Extractor.new(logger: @logger)
      end

      def fetch_post_payload_with_playwright(url, post_id)
        unless File.exist?(PLAYWRIGHT_SCRIPT)
          log("Fanbox post=#{post_id}: Playwright script not found at #{PLAYWRIGHT_SCRIPT}")
          return nil
        end

        unless playwright_available?
          log("Fanbox post=#{post_id}: Playwright package is not installed. Run: npm install playwright && npx playwright install chromium")
          return nil
        end

        output_path = File.join(Dir.tmpdir, "fanbox_post_#{post_id}_playwright.json")
        command = [
          "node",
          PLAYWRIGHT_SCRIPT,
          "--url", url,
          "--post-id", post_id.to_s,
          "--output", output_path,
          "--browser", @playwright_browser
        ]
        env = {}
        cookie_header = build_cookie_header
        env["FANBOX_COOKIE_HEADER"] = cookie_header unless cookie_header.empty?

        log("Fanbox post=#{post_id}: trying Playwright fallback (browser=#{@playwright_browser})")
        stdout, stderr, status = Open3.capture3(env, *command)
        log("Fanbox post=#{post_id}: Playwright stdout: #{stdout.strip}") unless stdout.to_s.strip.empty?
        log("Fanbox post=#{post_id}: Playwright stderr: #{stderr.strip}") unless stderr.to_s.strip.empty?
        unless status.success?
          log("Fanbox post=#{post_id}: Playwright fallback failed with exit=#{status.exitstatus}")
          return nil
        end

        json = JSON.parse(File.read(output_path))
        log("Fanbox post=#{post_id}: Playwright payload loaded")
        json
      rescue StandardError => e
        log("Fanbox post=#{post_id}: Playwright fallback error (#{e.message})")
        nil
      ensure
        File.delete(output_path) if output_path && File.exist?(output_path)
      end

      def load_manual_post_info_payload(post_id)
        path = @post_info_json_path.to_s.strip
        return nil if path.empty?
        return nil unless File.file?(path)

        parsed = JSON.parse(File.read(path))
        log("Fanbox post=#{post_id}: loaded payload from --fanbox-post-info-json (#{path})")
        parsed
      rescue StandardError => e
        log("Fanbox post=#{post_id}: failed to load --fanbox-post-info-json (#{e.message})")
        nil
      end

      def playwright_available?
        _stdout, _stderr, status = Open3.capture3("node", "-e", "import('playwright').then(()=>process.exit(0)).catch(()=>process.exit(1))")
        status.success?
      rescue StandardError
        false
      end
    end
  end
end

require_relative "fanbox/extractor"
