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
        extractor.extract_image_urls(payload)
      end

      def make_post_directory_name(post_id, payload)
        title = payload["title"] || "post"
        sanitize_directory_name(title, fallback: post_id.to_s.empty? ? "post" : post_id.to_s)
      end

      def extract_authenticity_token(html)
        extractor.extract_authenticity_token(html)
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

      def extractor
        @extractor ||= Extractor.new(logger: @logger)
      end
    end
  end
end

require_relative "fantia/extractor"
