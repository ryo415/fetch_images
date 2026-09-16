# frozen_string_literal: true

require "net/http"
require "uri"

module FetchImages
  class HttpTransport
    def initialize(cookies:, user_agent:, open_timeout:, read_timeout:, logger: nil, on_cookies: nil, connection: nil)
      @cookies = cookies
      @user_agent = user_agent
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @logger = logger
      @on_cookies = on_cookies
      @connection = connection
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

    def stream_download(url, referer: nil, headers: {})
      uri = URI(url)
      request_headers = headers.dup
      request_headers["Referer"] = referer if referer
      request = build_request(Net::HTTP::Get, uri, request_headers)

      with_http(uri) do |http|
        block_result = nil
        http.request(request) do |response|
          store_cookies(response)
          log("Download response #{uri} -> #{response.code}")
          unless response.is_a?(Net::HTTPSuccess)
            raise "Failed to download #{url}: #{response.code} #{response.message}"
          end

          block_result = yield(response)
        end
        block_result
      end
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

    def apply_cookies(hash)
      @cookies.merge!(hash.compact)
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
      @on_cookies&.call
      log("Stored cookies: #{cookie_keys.join(', ')}")
    end

    def cookie_keys
      @cookies.keys.sort
    end

    def build_request(request_class, uri, headers)
      request = request_class.new(uri)
      request["User-Agent"] = @user_agent
      headers.each { |key, value| request[key] = value }
      cookie_header = build_cookie_header
      request["Cookie"] = cookie_header unless cookie_header.empty?
      request
    end

    def append_query_params(uri, params)
      return uri if params.nil? || params.empty?

      query = URI.encode_www_form(params)
      updated_uri = uri.dup
      updated_uri.query = [updated_uri.query, query].compact.join("&")
      updated_uri
    end

    def with_http(uri, &block)
      return @connection.call(uri, &block) if @connection

      Net::HTTP.start(
        uri.host,
        uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: @open_timeout,
        read_timeout: @read_timeout,
        &block
      )
    end

    private

    def log(message)
      @logger&.call(message)
    end
  end
end
