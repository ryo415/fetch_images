# frozen_string_literal: true

require "json"
require "net/http"
require "set"
require "uri"
require "fileutils"
require "cgi"
require "unicode_normalize"

require_relative "errors"
require_relative "download_result"

module FetchImages
  IMAGE_EXTENSIONS = %w[.jpg .jpeg .png .gif .bmp .webp].freeze

  class Client
    USER_AGENT = "fetch-images/1.0 (+https://github.com/openai/autonomous-agents)".freeze

    attr_reader :session_id

    def initialize(session_id: nil)
      @session_id = session_id
      @cookies = {}
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

      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = USER_AGENT
        headers.each { |key, value| request[key] = value }
        cookie_header = build_cookie_header
        request["Cookie"] = cookie_header unless cookie_header.empty?
        response = http.request(request)
        unless response.is_a?(Net::HTTPSuccess)
          raise "HTTP request failed with status #{response.code}"
        end
        response
      end
    end

    def download_file(url, path)
      uri = URI(url)
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
        request = Net::HTTP::Get.new(uri)
        request["User-Agent"] = USER_AGENT
        cookie_header = build_cookie_header
        request["Cookie"] = cookie_header unless cookie_header.empty?

        http.request(request) do |response|
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
      normalized = value.to_s.unicode_normalize(:nfkd)
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
  end
end
