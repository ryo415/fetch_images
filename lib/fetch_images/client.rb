# frozen_string_literal: true

require "json"
require "net/http"
require "set"
require "uri"
require "fileutils"
require "cgi"
require "time"
require "digest"

begin
  require "unicode_normalize"
rescue LoadError
  # The optional unicode_normalize default gem may not be available in
  # minimal Ruby distributions. Filename sanitisation gracefully falls back
  # when it cannot be loaded.
end

require_relative "errors"
require_relative "download_result"

module FetchImages
  IMAGE_EXTENSIONS = %w[.jpg .jpeg .png .gif .bmp .webp].freeze

  class Client
    USER_AGENT = "fetch-images/1.0 (+https://github.com/openai/autonomous-agents)".freeze

    attr_reader :session_id

    def initialize(session_id: nil, credentials: nil)
      @session_id = session_id
      @credentials = credentials&.dup || {}
      @cookies = {}
    end

    def session_id
      @session_id ||= authenticate! if @session_id.nil? && !@credentials.empty?
      @session_id
    end

    def supports_url?(_url)
      raise NotImplementedError, "subclasses must implement #supports_url?"
    end

    def download_images(url, output_dir, overwrite: false, dry_run: false)
      post_id, payload = fetch_post_payload(url)
      image_urls = extract_image_urls(payload)
      result = DownloadResult.new(planned: image_urls.dup)
      return result if dry_run

      post_dir = File.join(output_dir, make_post_directory_name(post_id, payload))
      FileUtils.mkdir_p(post_dir)

      image_urls.each_with_index do |image_url, index|
        filename = build_filename(image_url, index + 1)
        target_path = File.join(post_dir, filename)
        if File.exist?(target_path) && !overwrite
          result.skipped << target_path
          next
        end

        download_file(image_url, target_path)
        result.downloaded << target_path
      end

      result
    end

    private

    def fetch_post_payload(_url)
      raise NotImplementedError, "subclasses must implement #fetch_post_payload"
    end

    def extract_image_urls(_payload)
      raise NotImplementedError, "subclasses must implement #extract_image_urls"
    end

    def make_post_directory_name(_post_id, _payload)
      raise NotImplementedError, "subclasses must implement #make_post_directory_name"
    end

    def apply_cookies(hash)
      @cookies.merge!(hash.compact)
    end

    def http_get(uri, headers: {}, params: {})
      uri = URI(uri)
      unless params.nil? || params.empty?
        query = URI.encode_www_form(params)
        uri = uri.dup
        uri.query = [uri.query, query].compact.join("&")
      end

      debug_log(
        "http.get request",
        method: "GET",
        url: uri.to_s,
        params: params,
        headers: sanitize_headers_for_log(headers),
        cookies: sanitize_cookies_for_log
      )

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = user_agent
        headers.each { |key, value| request[key] = value }
        cookie_header = build_cookie_header
        request["Cookie"] = cookie_header unless cookie_header.empty?
        response = http.request(request)
        store_cookies(response)
        debug_log(
          "http.get response",
          method: "GET",
          url: uri.to_s,
          status: "#{response.code} #{response.message}",
          headers: sanitize_response_headers_for_log(response),
          body_preview: response_preview_for_log(response.body),
          cookies: sanitize_cookies_for_log
        )
        unless response.is_a?(Net::HTTPSuccess)
          raise "HTTP request failed with status #{response.code}"
        end
        response
      end
    end

    def http_post_form(uri, form_data, headers: {})
      uri = URI(uri)
      debug_log(
        "http.post_form request",
        method: "POST",
        url: uri.to_s,
        form_data: sanitize_form_data_for_log(form_data),
        headers: sanitize_headers_for_log(headers),
        cookies: sanitize_cookies_for_log
      )
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        request = Net::HTTP::Post.new(uri)
        request["User-Agent"] = user_agent
        headers.each { |key, value| request[key] = value }
        cookie_header = build_cookie_header
        request["Cookie"] = cookie_header unless cookie_header.empty?
        request.set_form_data(form_data)
        response = http.request(request)
        store_cookies(response)
        debug_log(
          "http.post_form response",
          method: "POST",
          url: uri.to_s,
          status: "#{response.code} #{response.message}",
          headers: sanitize_response_headers_for_log(response),
          body_preview: response_preview_for_log(response.body),
          cookies: sanitize_cookies_for_log
        )
        response
      end
    end

    def download_file(url, path)
      uri = URI(url)
      debug_log(
        "download_file request",
        method: "GET",
        url: uri.to_s,
        path: path,
        cookies: sanitize_cookies_for_log
      )
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = user_agent
        cookie_header = build_cookie_header
        request["Cookie"] = cookie_header unless cookie_header.empty?

        http.request(request) do |response|
          store_cookies(response)
          debug_log(
            "download_file response",
            method: "GET",
            url: uri.to_s,
            status: "#{response.code} #{response.message}",
            headers: sanitize_response_headers_for_log(response),
            cookies: sanitize_cookies_for_log
          )
          unless response.is_a?(Net::HTTPSuccess)
            raise "Failed to download #{url}: #{response.code} #{response.message}"
          end

          File.open(path, "wb") do |file|
            response.read_body { |chunk| file.write(chunk) }
          end
        end
      end
    end

    def build_filename(image_url, index)
      uri = URI(image_url)
      name = File.basename(CGI.unescape(uri.path.to_s))
      name = "image_#{index}" if name.nil? || name.empty?
      name = sanitize_filename(name)
      format("%03d_%s", index, name)
    end

    def collect_image_urls(data, urls = Set.new)
      case data
      when Hash
        data.each_value { |value| collect_image_urls(value, urls) }
      when Array
        data.each { |value| collect_image_urls(value, urls) }
      when String
        urls << data if looks_like_image_url?(data)
      end
      urls
    end

    def looks_like_image_url?(value)
      uri = URI(value)
      return false unless uri.is_a?(URI::HTTP)

      ext = File.extname(CGI.unescape(uri.path.to_s)).downcase
      IMAGE_EXTENSIONS.include?(ext)
    rescue URI::InvalidURIError
      false
    end

    def slugify(value)
      normalized = value.to_s
      normalized = normalized.unicode_normalize(:nfkd) if normalized.respond_to?(:unicode_normalize)
      normalized = normalized.strip
      normalized = normalized.gsub(/\s+/, "-")
      normalized = normalized.gsub(/[^a-zA-Z0-9._-]/, "")
      normalized.empty? ? "post" : normalized
    end

    def sanitize_filename(filename)
      filename.gsub(File::SEPARATOR, "_").delete("\u0000")
    end

    def build_cookie_header
      return "" if @cookies.empty?

      @cookies.map { |key, value| "#{key}=#{value}" }.join("; ")
    end

    def store_cookies(response)
      cookies = response.get_fields("Set-Cookie")
      return unless cookies

      cookies.each do |cookie|
        pair = cookie.split(";", 2).first
        next unless pair

        key, value = pair.split("=", 2)
        next if key.nil?

        @cookies[key] = value
      end
      cookie_name = session_cookie_name
      @session_id ||= @cookies[cookie_name] if cookie_name
    end

    def authenticate!
      raise AuthenticationError, "Login credentials are not supported for this client"
    end

    def session_cookie_name
      nil
    end

    def user_agent
      USER_AGENT
    end

    def debug_logging_enabled?
      return @debug_logging_enabled unless @debug_logging_enabled.nil?

      raw = ENV["FETCH_IMAGES_DEBUG"]
      @debug_logging_enabled = ![nil, "", "0", "false", "off", "no"].include?(raw&.strip&.downcase)
    end

    def debug_log(message = nil, **context)
      return unless debug_logging_enabled?

      payload = { timestamp: Time.now.iso8601 }
      payload[:message] = message if message
      context.each do |key, value|
        payload[key] = normalize_debug_value(value)
      end

      $stderr.puts("[fetch-images] #{JSON.generate(payload)}")
    rescue JSON::GeneratorError
      fallback = payload.transform_values { |value| value.inspect }
      $stderr.puts("[fetch-images] #{fallback}")
    end

    def normalize_debug_value(value)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), result| result[k] = normalize_debug_value(v) }
      when Array
        value.map { |item| normalize_debug_value(item) }
      when Set
        value.map { |item| normalize_debug_value(item) }
      else
        value
      end
    end

    def sanitize_headers_for_log(headers)
      return {} unless headers

      headers.each_with_object({}) do |(key, value), result|
        normalized_key = key.to_s
        sanitized_value = if value.is_a?(Array)
          value.map { |item| sanitize_header_value_for_log(normalized_key, item) }
        else
          sanitize_header_value_for_log(normalized_key, value)
        end
        result[normalized_key] = sanitized_value
      end
    end

    def sanitize_response_headers_for_log(response)
      headers = {}
      response.each_header { |key, value| headers[key] = value }
      sanitize_headers_for_log(headers)
    end

    def sanitize_header_value_for_log(key, value)
      if sensitive_header?(key)
        filtered_value_for_log(value)
      else
        value
      end
    end

    def sanitize_cookies_for_log
      @cookies.each_with_object({}) do |(key, value), result|
        result[key] = filtered_value_for_log(value)
      end
    end

    def sanitize_form_data_for_log(form_data)
      return {} unless form_data

      form_data.each_with_object({}) do |(key, value), result|
        result[key] = filtered_value_for_log(value)
      end
    end

    def filtered_value_for_log(value)
      case value
      when nil
        nil
      when Array
        value.map { |item| filtered_value_for_log(item) }
      else
        string = value.to_s
        digest = Digest::SHA256.hexdigest(string)
        length = string.length
        "[FILTERED length=#{length} sha256=#{digest}]"
      end
    end

    def sensitive_header?(key)
      SENSITIVE_HEADER_NAMES.include?(key.to_s)
    end

    SENSITIVE_HEADER_NAMES = %w[
      Cookie cookie
      Authorization authorization
      Set-Cookie set-cookie
      X-Csrf-Token x-csrf-token
      X-CsrfToken x-csrftoken
    ].freeze

    def response_preview_for_log(body, limit: 500)
      return nil unless body

      snippet = body.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")
      return snippet if snippet.length <= limit

      snippet[0, limit] + "…"
    end
  end
end
