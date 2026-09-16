# frozen_string_literal: true

require_relative "test_helper"

class HttpTransportTest < Minitest::Test
  def test_http_error_updates_cookies_before_raising
    response = response(Net::HTTPForbidden, "403", "Forbidden", "session=new; Path=/")
    seen = []
    transport, cookies = transport_for(response, seen: seen, cookies: { "session" => "old" })

    error = assert_raises(RuntimeError) do
      transport.http_get("https://example.test/post", params: { "id" => "42" })
    end

    assert_equal "HTTP request failed with status 403", error.message
    assert_equal "new", cookies["session"]
    assert_equal "session=old", seen.first["Cookie"]
    assert_equal "/post?id=42", seen.first.path
  end

  def test_post_updates_cookies_and_preserves_form_and_headers
    response = response(Net::HTTPOK, "200", "OK", "token=next=value; Path=/")
    seen = []
    transport, cookies = transport_for(response, seen: seen, cookies: { "token" => "old" })

    result = transport.http_post_form(
      "https://example.test/login",
      { "email" => "test@example.test", "password" => "secret" },
      headers: { "Referer" => "https://example.test/sign_in" }
    )

    assert_same response, result
    assert_equal "next=value", cookies["token"]
    assert_equal "token=old", seen.first["Cookie"]
    assert_equal "https://example.test/sign_in", seen.first["Referer"]
    assert_equal "email=test%40example.test&password=secret", seen.first.body
  end

  def test_stream_download_updates_cookies_and_yields_inside_connection_block
    response = response(Net::HTTPOK, "200", "OK", "download=fresh; Path=/")
    active = false
    seen = []
    http = Object.new
    http.define_singleton_method(:request) do |request, &block|
      seen << request
      block.call(response)
    end
    connection = lambda do |_uri, &block|
      active = true
      block.call(http)
    ensure
      active = false
    end
    cookies = { "download" => "old" }
    transport = FetchImages::HttpTransport.new(
      cookies: cookies,
      user_agent: "test-agent",
      open_timeout: 15,
      read_timeout: 60,
      connection: connection
    )

    result = transport.stream_download(
      "https://cdn.example.test/image",
      referer: "https://example.test/post",
      headers: { "Accept" => "image/*" }
    ) do |yielded_response|
      assert active
      assert_same response, yielded_response
      :stored
    end

    assert_equal :stored, result
    assert_equal "fresh", cookies["download"]
    assert_equal "download=old", seen.first["Cookie"]
    assert_equal "https://example.test/post", seen.first["Referer"]
    assert_equal "image/*", seen.first["Accept"]
  end

  def test_stream_download_raises_existing_error_message_after_updating_cookies
    response = response(Net::HTTPNotFound, "404", "Not Found", "download=gone; Path=/")
    transport, cookies = transport_for(response, cookies: { "download" => "old" })

    error = assert_raises(RuntimeError) do
      transport.stream_download("https://cdn.example.test/missing") { flunk "must not yield" }
    end

    assert_equal "Failed to download https://cdn.example.test/missing: 404 Not Found", error.message
    assert_equal "gone", cookies["download"]
  end

  def test_cookie_parsing_preserves_equals_and_set_cookie_can_delete
    callbacks = 0
    cookies = {}
    transport = FetchImages::HttpTransport.new(
      cookies: cookies,
      user_agent: "test-agent",
      open_timeout: 15,
      read_timeout: 60,
      on_cookies: -> { callbacks += 1 }
    )

    transport.apply_cookie_header("first=a=b; second=value")
    assert_equal({ "first" => "a=b", "second" => "value" }, cookies)
    assert_equal 0, callbacks

    transport.store_cookies(response(Net::HTTPOK, "200", "OK", "first=; Path=/"))
    assert_equal({ "second" => "value" }, cookies)
    assert_equal 1, callbacks
  end

  def test_store_cookies_does_not_call_callback_without_set_cookie
    callbacks = 0
    transport = FetchImages::HttpTransport.new(
      cookies: {},
      user_agent: "test-agent",
      open_timeout: 15,
      read_timeout: 60,
      on_cookies: -> { callbacks += 1 }
    )

    transport.store_cookies(response(Net::HTTPOK, "200", "OK"))

    assert_equal 0, callbacks
  end

  private

  def response(klass, code, message, set_cookie = nil)
    klass.new("1.1", code, message).tap do |result|
      result.add_field("Set-Cookie", set_cookie) if set_cookie
    end
  end

  def transport_for(response, seen: [], cookies: {})
    http = Object.new
    http.define_singleton_method(:request) do |request, &block|
      seen << request
      block ? block.call(response) : response
    end
    connection = ->(_uri, &block) { block.call(http) }
    transport = FetchImages::HttpTransport.new(
      cookies: cookies,
      user_agent: "test-agent",
      open_timeout: 15,
      read_timeout: 60,
      connection: connection
    )
    [transport, cookies]
  end
end

class ClientHttpDelegationTest < Minitest::Test
  class LazyAuthClient < FetchImages::Client
    attr_reader :authentication_count

    private

    def session_cookie_name
      "session"
    end

    def authenticate!
      @authentication_count = @authentication_count.to_i + 1
      "authenticated"
    end
  end

  def test_cookie_update_does_not_replace_cached_session
    client = FetchImages::Clients::Fantia.new(session_id: "initial", cookie_header: "extra=a=b")
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.add_field("Set-Cookie", "_session_id=updated; Path=/")

    client.send(:store_cookies, response)

    assert_equal "initial", client.session_id
    assert_includes client.send(:build_cookie_header), "_session_id=updated"
    assert_includes client.send(:build_cookie_header), "extra=a=b"
  end

  def test_cookie_header_does_not_seed_session_or_trigger_authentication
    client = LazyAuthClient.new(cookie_header: "session=header=value")

    assert_nil client.authentication_count
    assert_nil client.session_id
    assert_equal "session=header=value", client.send(:build_cookie_header)
  end

  def test_response_cookie_seeds_an_uncached_session
    client = LazyAuthClient.new
    response = Net::HTTPOK.new("1.1", "200", "OK")
    response.add_field("Set-Cookie", "session=response=value; Path=/")

    client.send(:store_cookies, response)

    assert_equal "response=value", client.session_id
  end

  def test_credentials_authenticate_lazily_and_cache_the_result
    client = LazyAuthClient.new(credentials: { email: "person@example.test", password: "secret" })

    assert_nil client.authentication_count
    assert_equal "authenticated", client.session_id
    assert_equal "authenticated", client.session_id
    assert_equal 1, client.authentication_count
  end

  def test_download_file_passes_streaming_response_to_storage_delegate
    response = Object.new
    transport = Object.new
    transport.define_singleton_method(:stream_download) do |url, referer:, headers:, &block|
      raise "wrong URL" unless url == "https://cdn.example.test/image"
      raise "wrong referer" unless referer == "https://example.test/post"
      raise "wrong headers" unless headers == { "Accept" => "image/*" }

      block.call(response)
    end
    client = FetchImages::Client.new
    client.instance_variable_set(:@transport, transport)
    client.define_singleton_method(:save_response) do |path, yielded_response|
      raise "wrong response" unless yielded_response.equal?(response)

      "#{path}.jpg"
    end

    result = client.send(
      :download_file,
      "https://cdn.example.test/image",
      "/tmp/image",
      referer: "https://example.test/post",
      headers: { "Accept" => "image/*" }
    )

    assert_equal "/tmp/image.jpg", result
  end
end

class HttpFallbackCharacterizationTest < Minitest::Test
  FALLBACK_STATUSES = [401, 403, 404, 410, 422, 429].freeze

  def test_fantia_falls_back_for_documented_http_statuses
    FALLBACK_STATUSES.each do |status|
      client = fantia_client(api_error: RuntimeError.new("HTTP request failed with status #{status}"))

      post_id, payload = client.send(:fetch_post_payload, "https://fantia.jp/posts/42")

      assert_equal "42", post_id
      assert_equal ["https://cdn.example.test/fallback.jpg"], payload.dig("post_contents", 0, "images")
    end
  end

  def test_fantia_propagates_500_and_invalid_json
    error = assert_raises(RuntimeError) do
      fantia_client(api_error: RuntimeError.new("HTTP request failed with status 500"))
        .send(:fetch_post_payload, "https://fantia.jp/posts/42")
    end
    assert_equal "HTTP request failed with status 500", error.message

    assert_raises(JSON::ParserError) do
      fantia_client(api_body: "not json").send(:fetch_post_payload, "https://fantia.jp/posts/42")
    end
  end

  def test_fanbox_falls_back_for_documented_http_statuses_and_preserves_attempt_order
    expected_attempts = [
      ["https://api.fanbox.cc/post.info", "https://creator.fanbox.cc/posts/42", "https://creator.fanbox.cc", "same-site"],
      ["https://api.fanbox.cc/post.info", "https://www.fanbox.cc/@creator/posts/42", "https://www.fanbox.cc", "same-site"],
      ["https://api.fanbox.cc/post.info", "https://www.fanbox.cc/@creator/posts/42", "https://www.fanbox.cc", "cross-site"],
      ["https://api.fanbox.cc/post.info", "https://www.fanbox.cc/", "https://www.fanbox.cc", "same-site"],
      ["https://creator.fanbox.cc/api/post.info", "https://creator.fanbox.cc/posts/42", "https://creator.fanbox.cc", "same-origin"]
    ]

    FALLBACK_STATUSES.each do |status|
      calls = []
      client = fanbox_client(calls: calls, api_error: RuntimeError.new("HTTP request failed with status #{status}"))

      post_id, payload = client.send(:fetch_post_payload, "https://creator.fanbox.cc/posts/42")

      assert_equal "42", post_id
      assert_equal ["https://cdn.example.test/fallback.jpg"], payload.dig("body", "images")
      actual_attempts = calls.drop(1).map do |url, headers, params|
        assert_equal({ "postId" => "42" }, params)
        [url, headers["Referer"], headers["Origin"], headers["Sec-Fetch-Site"]]
      end
      assert_equal expected_attempts, actual_attempts
    end
  end

  def test_fanbox_propagates_500_and_invalid_json_without_later_attempts
    calls = []
    error = assert_raises(RuntimeError) do
      fanbox_client(calls: calls, api_error: RuntimeError.new("HTTP request failed with status 500"))
        .send(:fetch_post_payload, "https://creator.fanbox.cc/posts/42")
    end
    assert_equal "HTTP request failed with status 500", error.message
    assert_equal 2, calls.length

    calls = []
    assert_raises(JSON::ParserError) do
      fanbox_client(calls: calls, api_body: "not json")
        .send(:fetch_post_payload, "https://creator.fanbox.cc/posts/42")
    end
    assert_equal 2, calls.length
  end

  private

  def page_response
    Struct.new(:body).new("<html><title>Fallback</title></html>")
  end

  def api_response(body)
    Struct.new(:body).new(body)
  end

  def fantia_client(api_error: nil, api_body: nil)
    client = FetchImages::Clients::Fantia.new(session_id: "session")
    page = page_response
    api = api_response(api_body)
    client.define_singleton_method(:http_get) do |url, **_|
      if url.include?("/api/")
        raise api_error if api_error

        api
      else
        page
      end
    end
    client.define_singleton_method(:extract_image_urls_from_html) do |*_args, **_kwargs|
      ["https://cdn.example.test/fallback.jpg"]
    end
    client
  end

  def fanbox_client(calls:, api_error: nil, api_body: nil)
    client = FetchImages::Clients::Fanbox.new(session_id: "session")
    page = page_response
    api = api_response(api_body)
    client.define_singleton_method(:http_get) do |url, headers: {}, params: {}|
      calls << [url, headers, params]
      if url.include?("post.info")
        raise api_error if api_error

        api
      else
        page
      end
    end
    client.define_singleton_method(:extract_image_urls_from_html) do |*_args, **_kwargs|
      ["https://cdn.example.test/fallback.jpg"]
    end
    client
  end
end
