# frozen_string_literal: true

require "json"
require "nokogiri"
require "uri"

module FetchImages
  module Clients
    class Fantia < Client
      URL_PATTERN = %r{https?://(?:www\.)?fantia\.jp/(?:fanclubs/\d+/)?posts/(?<id>\d+)}.freeze
      API_URL_TEMPLATE = "https://fantia.jp/api/v1/posts/%{post_id}".freeze
      LOGIN_PAGE_URL = "https://fantia.jp/users/sign_in".freeze
      LOGIN_URL = "https://fantia.jp/users/sign_in".freeze

      def supports_url?(url)
        !!URL_PATTERN.match(url)
      end

      private

      def session_cookie_name
        "_session_id"
      end

      def authenticate!
        email = @credentials[:email]
        password = @credentials[:password]
        raise AuthenticationError, "Fantia email and password are required" if email.to_s.empty? || password.to_s.empty?

        login_page = http_get(LOGIN_PAGE_URL, headers: { "Accept" => "text/html" })
        token = extract_authenticity_token(login_page.body)
        raise AuthenticationError, "Failed to obtain Fantia authenticity token" unless token

        headers = {
          "Referer" => LOGIN_PAGE_URL,
          "Content-Type" => "application/x-www-form-urlencoded"
        }
        form_data = {
          "user[email]" => email,
          "user[password]" => password,
          "authenticity_token" => token
        }

        response = http_post_form(LOGIN_URL, form_data, headers: headers)
        unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
          raise AuthenticationError, "Fantia login failed with status #{response.code}"
        end

        session_cookie = @cookies[session_cookie_name]
        raise AuthenticationError, "Fantia login did not return a session cookie" unless session_cookie

        session_cookie
      end

      def fetch_post_payload(url)
        match = URL_PATTERN.match(url)
        raise UnsupportedUrlError, url unless match

        post_id = match[:id]
        api_url = format(API_URL_TEMPLATE, post_id: post_id)
        apply_cookies("_session_id" => session_id) if session_id
        page = http_get(url, headers: { "Accept" => "text/html", "Referer" => url })
        csrf_token = extract_authenticity_token(page.body)
        log("Fantia post=#{post_id}: fetched post page, csrf_token_present=#{!csrf_token.to_s.empty?}")

        log("Fantia post=#{post_id}: trying API #{api_url}")
        headers = {
          "Accept" => "application/json",
          "Referer" => url,
          "X-Requested-With" => "XMLHttpRequest"
        }
        headers["X-CSRF-Token"] = csrf_token unless csrf_token.to_s.empty?

        begin
          response = http_get(api_url, headers: headers)
          data = JSON.parse(response.body)
          post = data["post"] || data
          log("Fantia post=#{post_id}: API payload loaded")
          [post_id, post]
        rescue StandardError => e
          raise unless fallback_candidate_error?(e)

          log("Fantia post=#{post_id}: API failed (#{e.message}), fallback to HTML parse")
          image_urls = extract_image_urls_from_html(page.body, url, post_id: post_id)
          log("Fantia post=#{post_id}: HTML fallback extracted #{image_urls.size} candidate(s)")
          fallback_post = {
            "title" => extract_page_title(page.body),
            "post_contents" => [{ "images" => image_urls }],
            "fanclub" => {}
          }
          [post_id, fallback_post]
        end
      end

      def extract_image_urls(payload)
        urls = Set.new
        Array(payload["post_contents"]).each do |content|
          urls.merge(collect_fantia_image_urls(content))
        end
        Array(payload["post_attachments"]).each do |attachment|
          urls.merge(collect_fantia_image_urls(attachment))
        end

        urls.merge(collect_fantia_image_urls(payload)) if urls.empty?
        if urls.empty?
          %w[thumb cover_image_url cover_image].each do |key|
            value = payload[key]
            urls << value if value.is_a?(String) && fantia_image_url?(value)
          end
        end

        filtered_urls = select_preferred_variants(urls.to_a)
        log("Fantia extraction result: #{urls.size} URL(s), selected #{filtered_urls.size} variant(s)")
        filtered_urls
      end

      def make_post_directory_name(post_id, payload)
        title = payload["title"] || "post"
        sanitize_directory_name(title, fallback: post_id.to_s.empty? ? "post" : post_id.to_s)
      end

      def extract_authenticity_token(html)
        html[/name="authenticity_token"\s+value="([^"]+)"/, 1] ||
          html[/meta\s+name="csrf-token"\s+content="([^"]+)"/, 1]
      end

      def fallback_candidate_error?(error)
        message = error.message.to_s
        return false unless message.include?("HTTP request failed with status")

        status = message[/status\s+(\d{3})/, 1]&.to_i
        return true if status.nil?

        [401, 403, 404, 410, 422, 429].include?(status)
      end

      def extract_page_title(html)
        doc = Nokogiri::HTML(html)
        doc.at_css("meta[property='og:title']")&.[]("content") ||
          doc.at_css("title")&.text&.strip ||
          "post"
      end

      def extract_image_urls_from_html(html, base_url, post_id:)
        doc = Nokogiri::HTML(html)
        base_uri = URI(base_url)
        urls = extract_image_urls_from_embedded_json(doc, post_id)
        log("Fantia HTML parse: embedded JSON yielded #{urls.size} URL(s)")
        return urls.to_a unless urls.empty?

        urls = extract_image_urls_from_script_text(doc, base_uri, post_id)
        log("Fantia HTML parse: script scan yielded #{urls.size} URL(s)")
        return urls.to_a unless urls.empty?

        urls = extract_image_urls_from_raw_html(html, base_uri, post_id)
        log("Fantia HTML parse: raw HTML scan yielded #{urls.size} URL(s)")
        return urls.to_a unless urls.empty?

        # Fallback path for pages that do not expose usable JSON payloads.
        urls = Set.new

        doc.css("img").each do |img|
          %w[data-src data-original data-url data-image src].each do |attr|
            candidate = img[attr]
            next if candidate.to_s.strip.empty?

            add_absolute_image_url(urls, base_uri, candidate, strict: true)
          end

          %w[srcset data-srcset].each do |attr|
            srcset = img[attr]
            next if srcset.to_s.strip.empty?

            srcset.split(",").each do |entry|
              candidate = entry.strip.split(/\s+/, 2).first
              next if candidate.to_s.strip.empty?

              add_absolute_image_url(urls, base_uri, candidate, strict: true)
            end
          end
        end

        doc.css("a[href], a[data-download]").each do |a|
          candidate = a["href"] || a["data-download"]
          next if candidate.to_s.strip.empty?

          add_absolute_image_url(urls, base_uri, candidate, strict: true)
        end

        log("Fantia HTML parse: element scan yielded #{urls.size} URL(s)")
        urls.to_a
      end

      def add_absolute_image_url(urls, base_uri, candidate, strict: false)
        absolute = URI.join(base_uri, candidate).to_s
        if strict
          return unless likely_post_image_url?(absolute)
        else
          return unless fantia_image_url?(absolute)
        end

        urls << absolute
      rescue URI::InvalidURIError
        nil
      end

      def extract_image_urls_from_embedded_json(doc, post_id)
        urls = Set.new
        doc.css("script").each do |script|
          json_text = script.text.to_s.strip
          next if json_text.empty?
          next unless likely_embedded_json?(script, json_text)

          begin
            data = JSON.parse(json_text)
          rescue JSON::ParserError
            next
          end

          post_payload = find_post_payload(data, post_id)
          next unless post_payload

          collect_fantia_image_urls(post_payload).each do |url|
            urls << url if likely_post_image_url?(url)
          end
        end
        urls
      end

      def likely_embedded_json?(script, json_text)
        type = script["type"].to_s
        return true if script["id"].to_s == "__NEXT_DATA__"
        return true if type.include?("json")

        json_text.include?("\"post_contents\"") || json_text.include?("\"post_attachments\"")
      end

      def find_post_payload(value, post_id)
        case value
        when Hash
          id = value["id"] || value["post_id"] || value["postId"]
          has_post_shape = value.key?("post_contents") || value.key?("post_attachments")
          return value if has_post_shape && (post_id.nil? || id.to_s == post_id.to_s)

          value.each_value do |child|
            found = find_post_payload(child, post_id)
            return found if found
          end
        when Array
          value.each do |child|
            found = find_post_payload(child, post_id)
            return found if found
          end
        end
        nil
      end

      def likely_post_image_url?(url)
        uri = URI(url)
        return false unless uri.is_a?(URI::HTTP) && uri.host

        host = uri.host.downcase
        path = uri.path.to_s.downcase

        return false unless host.include?("fantia") || host.include?("fantia-images")
        return false if non_post_asset_path?(path)

        path.include?("post_content") ||
          path.include?("post_attachment") ||
          path.include?("post_images") ||
          path.include?("/uploads/") ||
          path.include?("/storage/")
      rescue URI::InvalidURIError
        false
      end

      def extract_image_urls_from_script_text(doc, base_uri, post_id)
        urls = Set.new
        script_pattern = candidate_url_pattern

        doc.css("script").each do |script|
          text = script.text.to_s
          next if text.empty?

          normalized = normalize_escaped_text(text)
          normalized.scan(script_pattern) do |match|
            candidate = match.is_a?(Array) ? match.compact.first : match
            next if candidate.to_s.strip.empty?
            next if post_id && !candidate.include?(post_id.to_s) && candidate.include?("/posts/")

            add_absolute_image_url(urls, base_uri, candidate, strict: true)
          end
        end

        urls
      end

      def extract_image_urls_from_raw_html(html, base_uri, post_id)
        urls = Set.new
        normalized = normalize_escaped_text(html)
        normalized.scan(candidate_url_pattern) do |match|
          candidate = match.is_a?(Array) ? match.compact.first : match
          next if candidate.to_s.strip.empty?
          next if post_id && !candidate.include?(post_id.to_s) && candidate.include?("/posts/")

          add_absolute_image_url(urls, base_uri, candidate, strict: true)
        end
        urls
      end

      def normalize_escaped_text(text)
        text.to_s
            .gsub("\\/", "/")
            .gsub(/\\u002f/i, "/")
            .gsub(/\\u003a/i, ":")
            .gsub(/\\u0026/i, "&")
      end

      def candidate_url_pattern
        %r{
          (?:(?:https?:)?//|/)?
          [^"'\s\\)]*
          (?:
            post_content|
            post_attachment|
            post_images|
            uploads/|
            storage/
          )
          [^"'\s\\)]*
        }ix
      end

      def fantia_image_url?(url)
        looks_like_image_url?(url) || likely_post_image_url?(url)
      end

      def non_post_asset_path?(path)
        %w[
          /thumb
          /thumbnail
          /avatar
          /icon
          /logo
          /banner
          /ads
          /advert
          /lp/
          /campaign
        ].any? { |segment| path.include?(segment) }
      end

      def collect_fantia_image_urls(data, urls = Set.new)
        case data
        when Hash
          data.each_value { |value| collect_fantia_image_urls(value, urls) }
        when Array
          data.each { |value| collect_fantia_image_urls(value, urls) }
        when String
          urls << data if fantia_image_url?(data)
        end
        urls
      end

      def select_preferred_variants(urls)
        grouped = Hash.new { |hash, key| hash[key] = [] }
        urls.each do |url|
          grouped[variant_group_key(url)] << url
        end

        grouped.values
               .map { |candidates| candidates.max_by { |url| variant_score(url) } }
               .compact
               .reject { |url| unwanted_variant?(url) }
      end

      def variant_group_key(url)
        filename = File.basename(URI(url).path.to_s).downcase
        return filename if filename.empty?

        if (uuid = filename[/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/])
          return uuid
        end

        # Generic fallback: strip known size prefixes.
        filename.sub(/\A(?:thumb(?:_webp)?|micro|small|medium|large|main|ogp)_/, "")
      rescue URI::InvalidURIError
        url
      end

      def variant_score(url)
        path = URI(url).path.to_s.downcase
        basename = File.basename(path)

        score = 0
        score += 100 if basename.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\./)
        score += 90 if basename.start_with?("main_")
        score += 80 if basename.start_with?("large_")
        score += 70 if basename.start_with?("medium_")
        score += 60 if basename.start_with?("small_")
        score += 50 if basename.start_with?("micro_")
        score += 40 if basename.start_with?("thumb_")
        score += 30 if basename.start_with?("thumb_webp_")
        score += 10 if basename.start_with?("ogp_")

        # Prefer non-webp unless that's the only available source.
        score += 5 unless path.end_with?(".webp")
        score
      rescue URI::InvalidURIError
        -1
      end

      def unwanted_variant?(url)
        basename = File.basename(URI(url).path.to_s).downcase
        basename.start_with?("thumb_", "thumb_webp_", "micro_", "small_", "ogp_")
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
