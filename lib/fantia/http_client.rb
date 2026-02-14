# frozen_string_literal: true

require 'net/http'
require 'uri'

module Fantia
  class HttpClient
    DEFAULT_USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) ' \
                         'AppleWebKit/537.36 (KHTML, like Gecko) ' \
                         'Chrome/119.0.0.0 Safari/537.36'

    def initialize(manual_cookie: nil, logger: nil)
      @manual_cookie = manual_cookie&.strip
      @manual_cookie = nil if @manual_cookie&.empty?
      @logger = logger
      @cookie_jar = {}
      log('Initialized HTTP client with manual cookie override') if @manual_cookie
    end

    def get(uri, depth = 0)
      raise "Too many redirects while fetching #{uri}" if depth > 10

      request = Net::HTTP::Get.new(uri)
      apply_default_headers(request)
      log("Fetching #{uri}")

      response = http_client_for(uri).request(request)
      store_cookies(response)
      log_http_result('GET', uri, response)

      case response
      when Net::HTTPRedirection
        location = response['location']
        raise "Redirect missing location header for #{uri}" unless location

        new_uri = URI.join(uri, location)
        log("Following redirect to #{new_uri}")
        get(new_uri, depth + 1)
      when Net::HTTPSuccess
        body = response.body
        log("Fetched #{uri} (#{body&.bytesize || 0} bytes)")
        body
      else
        raise "Failed to fetch #{uri} (status: #{response.code})"
      end
    end

    def download(uri, target, depth = 0, referer: nil)
      raise "Too many redirects while downloading #{uri}" if depth > 5

      request = Net::HTTP::Get.new(uri)
      apply_default_headers(request)
      request['Referer'] = referer.to_s if referer
      request['Accept'] = 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8'
      log("Downloading #{uri} (referer: #{referer || 'none'})")

      http_client_for(uri).request(request) do |response|
        store_cookies(response)
        log_http_result('GET', uri, response)

        case response
        when Net::HTTPSuccess
          File.open(target, 'wb') do |file|
            total = 0
            response.read_body do |chunk|
              file.write(chunk)
              total += chunk.bytesize
            end
            log("Saved #{target} (#{total} bytes)")
          end
        when Net::HTTPRedirection
          location = response['location']
          raise "Redirect missing location header for #{uri}" unless location

          new_uri = URI.join(uri, location)
          log("Image download redirect to #{new_uri}")
          download(new_uri, target, depth + 1, referer: referer)
        else
          warn "Failed to download #{uri} (status: #{response.code})"
        end
      end
    end

    def post_form(uri, params, referer: nil)
      request = Net::HTTP::Post.new(uri)
      apply_default_headers(request)
      request['Referer'] = referer.to_s if referer
      request.set_form_data(params)
      log("Posting form to #{uri}")
      log("Form payload summary: #{masked_form_params(params)}")

      response = http_client_for(uri).request(request)
      store_cookies(response)
      log_http_result('POST', uri, response)
      response
    end

    private

    def http_client_for(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.read_timeout = 60
      http.open_timeout = 15
      http
    end

    def apply_default_headers(request)
      request['User-Agent'] = DEFAULT_USER_AGENT
      cookie_header = combined_cookie_header
      if cookie_header
        request['Cookie'] = cookie_header
        log("Attached cookies: #{masked_cookie_header(cookie_header)}")
      end
    end

    def combined_cookie_header
      parts = []
      parts << @manual_cookie if @manual_cookie
      jar = @cookie_jar.map { |key, value| "#{key}=#{value}" }
      parts.concat(jar) unless jar.empty?
      parts.empty? ? nil : parts.join('; ')
    end

    def store_cookies(response)
      cookies = response.get_fields('set-cookie')
      return unless cookies

      cookies.each do |cookie|
        name_value = cookie.split(';', 2).first
        next unless name_value

        name, value = name_value.split('=', 2)
        next unless name

        name = name.strip
        value = value ? value.strip : ''

        if value.empty?
          @cookie_jar.delete(name)
          log("Cleared cookie #{name}")
        else
          @cookie_jar[name] = value
          log("Stored cookie #{name}")
        end
      end
    end

    def log(message)
      @logger&.call(message)
    end

    def log_http_result(method, uri, response)
      log("#{method} #{uri} -> #{response.code} #{response.message}")
    end

    def masked_cookie_header(header)
      header.split(/;\s*/).map do |part|
        name, value = part.split('=', 2)
        next part unless value

        masked_value = value.empty? ? '' : '[hidden]'
        "#{name}=#{masked_value}"
      end.join('; ')
    end

    def masked_form_params(params)
      params.map do |key, value|
        masked_value = if key.to_s.match?(/password|otp|token|code/i)
                         '[hidden]'
                       elsif value.nil? || value.to_s.empty?
                         '(empty)'
                       else
                         value.to_s[0, 40]
                       end
        "#{key}=#{masked_value}"
      end.join(', ')
    end
  end
end
