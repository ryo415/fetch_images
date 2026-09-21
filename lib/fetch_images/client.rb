# frozen_string_literal: true

require "json"
require "net/http"
require "set"
require "uri"
require "fileutils"

require_relative "errors"
require_relative "download_result"
require_relative "image_urls"
require_relative "file_storage"
require_relative "http_transport"

module FetchImages
  class Client
    include ImageUrls

    USER_AGENT = "fetch-images/1.0 (+https://github.com/openai/autonomous-agents)".freeze
    OPEN_TIMEOUT = 15
    READ_TIMEOUT = 60

    attr_reader :session_id

    def initialize(session_id: nil, credentials: nil, cookie_header: nil, logger: nil)
      @session_id = session_id
      @credentials = credentials&.dup || {}
      @logger = logger
      @cookies = {}
      @transport = HttpTransport.new(
        cookies: @cookies,
        logger: @logger,
        user_agent: USER_AGENT,
        open_timeout: OPEN_TIMEOUT,
        read_timeout: READ_TIMEOUT,
        on_cookies: -> { @session_id ||= @cookies[session_cookie_name] if session_cookie_name }
      )
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

    private :collect_image_urls, :looks_like_image_url?

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
      @transport.apply_cookies(hash)
    end

    def apply_cookie_header(cookie_header)
      @transport.apply_cookie_header(cookie_header)
    end

    def http_get(uri, headers: {}, params: {})
      @transport.http_get(uri, headers: headers, params: params)
    end

    def http_post_form(uri, form_data, headers: {})
      @transport.http_post_form(uri, form_data, headers: headers)
    end

    def download_file(url, path, referer: nil, headers: {})
      log("Downloading #{URI(url)} -> #{path}")
      @transport.stream_download(url, referer: referer, headers: headers) do |response|
        save_response(path, response)
      end
    end

    def build_filename(image_url, index)
      storage.build_filename(image_url, index)
    end

    def slugify(value)
      storage.slugify(value)
    end

    def sanitize_directory_name(name, fallback: "post")
      storage.sanitize_directory_name(name, fallback: fallback)
    end

    def sanitize_filename(filename)
      storage.sanitize_filename(filename)
    end

    def ensure_extension(path, content_type)
      storage.ensure_extension(path, content_type)
    end

    def build_cookie_header
      @transport.build_cookie_header
    end

    def store_cookies(response)
      @transport.store_cookies(response)
    end

    def append_query_params(uri, params)
      @transport.append_query_params(uri, params)
    end

    def build_request(request_class, uri, headers)
      @transport.build_request(request_class, uri, headers)
    end

    def with_http(uri, &block)
      @transport.with_http(uri, &block)
    end

    def save_response(path, response)
      storage.save_response(path, response)
    end

    def existing_download_path(path)
      storage.existing_download_path(path)
    end

    def storage
      @storage ||= FileStorage.new
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
      @transport.cookie_keys
    end
  end
end
