# frozen_string_literal: true

require "json"
require "net/http"
require "set"
require "tempfile"
require "uri"
require "fileutils"
require "cgi"

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
    OPEN_TIMEOUT = 15
    READ_TIMEOUT = 60

    attr_reader :session_id

    def initialize(session_id: nil, credentials: nil, cookie_header: nil, logger: nil)
      @session_id = session_id
      @credentials = credentials&.dup || {}
      @cookies = {}
      @logger = logger
      apply_cookie_header(cookie_header)
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
        existing_target = existing_download_path(target_path)
        if existing_target && !overwrite
          result.skipped << existing_target
          next
        end

        headers = extra_download_headers(url, image_url)
        referer = download_referer(url, image_url)
        saved_path = download_file(image_url, target_path, referer: referer, headers: headers)
        result.downloaded << saved_path
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

    def extra_download_headers(_page_url, _image_url)
      {}
    end

    def download_referer(page_url, _image_url)
      page_url
    end

    def apply_cookies(hash)
      @cookies.merge!(hash.compact)
    end

    def apply_cookie_header(cookie_header)
      return if cookie_header.to_s.strip.empty?

      cookie_header.split(";").each do |part|
        key, value = part.split("=", 2)
        next if key.to_s.strip.empty? || value.nil?

        @cookies[key.strip] = value.strip
      end
      log("Loaded cookies from cookie header: #{cookie_keys.join(', ')}")
    end

    def http_get(uri, headers: {}, params: {})
      uri = append_query_params(URI(uri), params)
      request = build_request(Net::HTTP::Get, uri, headers)

      with_http(uri) do |http|
        log("HTTP GET #{uri}")
        response = http.request(request)
        store_cookies(response)
        log("HTTP GET #{uri} -> #{response.code}")
        raise "HTTP request failed with status #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        response
      end
    end

    def http_post_form(uri, form_data, headers: {})
      uri = URI(uri)
      request = build_request(Net::HTTP::Post, uri, headers)
      request.set_form_data(form_data)

      with_http(uri) do |http|
        log("HTTP POST #{uri}")
        response = http.request(request)
        store_cookies(response)
        log("HTTP POST #{uri} -> #{response.code}")
        response
      end
    end

    def download_file(url, path, referer: nil, headers: {})
      uri = URI(url)
      log("Downloading #{uri} -> #{path}")
      request_headers = headers.dup
      request_headers["Referer"] = referer if referer
      request = build_request(Net::HTTP::Get, uri, request_headers)

      with_http(uri) do |http|
        http.request(request) do |response|
          store_cookies(response)
          log("Download response #{uri} -> #{response.code}")
          unless response.is_a?(Net::HTTPSuccess)
            raise "Failed to download #{url}: #{response.code} #{response.message}"
          end

          return save_response(path, response)
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

    def sanitize_directory_name(name, fallback: "post")
      sanitized = name.to_s
      sanitized = sanitized.unicode_normalize(:nfkc) if sanitized.respond_to?(:unicode_normalize)
      sanitized = sanitized.delete("\u0000")
      sanitized = sanitized.gsub(/[[:cntrl:]]+/, " ")
      sanitized = sanitized.gsub(/[\\\/:*?"<>|]/, "_")
      sanitized = sanitized.gsub(/\s+/, " ").strip
      sanitized = sanitized.gsub(/\A\.+/, "").gsub(/\.+\z/, "")
      sanitized.empty? ? fallback : sanitized
    end

    def sanitize_filename(filename)
      sanitized = filename.gsub(File::SEPARATOR, "_").delete("\u0000")
      sanitized = sanitized.gsub(/\.+\z/, "")
      sanitized.empty? ? "image" : sanitized
    end

    def ensure_extension(path, content_type)
      return path unless File.extname(path).empty?

      ext = case content_type.to_s.downcase
            when /image\/jpe?g/
              ".jpg"
            when /image\/png/
              ".png"
            when /image\/webp/
              ".webp"
            when /image\/gif/
              ".gif"
            when /image\/bmp/
              ".bmp"
            when /image\/avif/
              ".avif"
            when /video\/mp4/
              ".mp4"
            when /video\/webm/
              ".webm"
            when /application\/vnd\.apple\.mpegurl/, /application\/x-mpegurl/
              ".m3u8"
            else
              ".img"
            end
      "#{path}#{ext}"
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

        if value.to_s.empty?
          @cookies.delete(key)
        else
          @cookies[key] = value
        end
      end
      cookie_name = session_cookie_name
      @session_id ||= @cookies[cookie_name] if cookie_name
      log("Stored cookies: #{cookie_keys.join(', ')}")
    end

    def append_query_params(uri, params)
      return uri if params.nil? || params.empty?

      query = URI.encode_www_form(params)
      updated_uri = uri.dup
      updated_uri.query = [updated_uri.query, query].compact.join("&")
      updated_uri
    end

    def build_request(request_class, uri, headers)
      request = request_class.new(uri)
      request["User-Agent"] = USER_AGENT
      headers.each { |key, value| request[key] = value }
      cookie_header = build_cookie_header
      request["Cookie"] = cookie_header unless cookie_header.empty?
      request
    end

    def with_http(uri)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
        yield(http)
      end
    end

    def save_response(path, response)
      save_path = ensure_extension(path, response["Content-Type"])
      FileUtils.mkdir_p(File.dirname(save_path))

      Tempfile.create([File.basename(save_path), ".part"], File.dirname(save_path), binmode: true) do |file|
        response.read_body { |chunk| file.write(chunk) }
        file.flush
        file.close

        File.delete(save_path) if File.exist?(save_path)
        File.rename(file.path, save_path)
      end

      save_path
    end

    def existing_download_path(path)
      return path if File.exist?(path)
      return nil unless File.extname(path).empty?

      Dir.glob("#{path}.*").sort.first
    end

    def authenticate!
      raise AuthenticationError, "Login credentials are not supported for this client"
    end

    def session_cookie_name
      nil
    end

    def log(message)
      @logger&.call(message)
    end

    def cookie_keys
      @cookies.keys.sort
    end
  end
end
