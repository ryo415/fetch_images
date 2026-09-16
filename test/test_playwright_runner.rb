# frozen_string_literal: true

require_relative "test_helper"

class PlaywrightRunnerTest < Minitest::Test
  Status = Struct.new(:success?, :exitstatus)

  def test_runner_parses_json_and_removes_output_directory
    output_path = nil
    status = Status.new(true, 0)
    capture = lambda do |env, *command|
      assert_equal({ "COOKIE_FOR_TEST" => "session=dummy" }, env)
      refute_includes command, "session=dummy"
      assert_equal ["node", "helper.mjs", "--url", "https://example.test/post"], command[0...-2]
      assert_equal "--output", command[-2]
      output_path = command[-1]
      File.write(output_path, '{"videos":[]}')
      ["stdout", "stderr", status]
    end
    yielded = nil
    runner = FetchImages::PlaywrightRunner.new(capture: capture)

    result = runner.run(
      node: "node",
      script: "helper.mjs",
      args: ["--url", "https://example.test/post"],
      env: { "COOKIE_FOR_TEST" => "session=dummy" }
    ) { |*values| yielded = values }

    assert_equal({ "videos" => [] }, result)
    assert_equal ["stdout", "stderr", status], yielded
    refute File.exist?(output_path)
    refute Dir.exist?(File.dirname(output_path))
  end

  def test_runner_yields_nonzero_status_and_returns_nil_without_reading_output
    output_path = nil
    status = Status.new(false, 7)
    capture = lambda do |_env, *command|
      output_path = command.last
      ["failure out", "failure err", status]
    end
    yielded = nil

    result = FetchImages::PlaywrightRunner.new(capture: capture).run(
      node: "node", script: "helper.mjs", args: [], env: {}
    ) { |*values| yielded = values }

    assert_nil result
    assert_equal ["failure out", "failure err", status], yielded
    refute Dir.exist?(File.dirname(output_path))
  end

  def test_runner_removes_temporary_directory_after_invalid_json
    output_path = nil
    capture = lambda do |_env, *command|
      output_path = command.last
      File.write(output_path, "not json")
      ["", "", Status.new(true, 0)]
    end

    assert_raises(JSON::ParserError) do
      FetchImages::PlaywrightRunner.new(capture: capture).run(
        node: "node", script: "helper.mjs", args: [], env: {}
      )
    end
    refute Dir.exist?(File.dirname(output_path))
  end

  def test_runner_removes_temporary_directory_when_output_is_missing
    output_path = nil
    capture = lambda do |_env, *command|
      output_path = command.last
      ["", "", Status.new(true, 0)]
    end

    assert_raises(Errno::ENOENT) do
      FetchImages::PlaywrightRunner.new(capture: capture).run(
        node: "node", script: "helper.mjs", args: [], env: {}
      )
    end
    refute Dir.exist?(File.dirname(output_path))
  end

  def test_runner_removes_temporary_directory_when_capture_raises
    output_path = nil
    capture = lambda do |_env, *command|
      output_path = command.last
      raise Errno::ENOENT, "node-test"
    end

    assert_raises(Errno::ENOENT) do
      FetchImages::PlaywrightRunner.new(capture: capture).run(
        node: "node", script: "helper.mjs", args: [], env: {}
      )
    end
    refute Dir.exist?(File.dirname(output_path))
  end

  def test_fanbox_keeps_node_arguments_logs_and_nil_failure_fallback
    messages = []
    client = FetchImages::Clients::Fanbox.new(
      cookie_header: "FANBOXSESSID=dummy",
      logger: ->(message) { messages << message },
      playwright: true,
      playwright_browser: "firefox"
    )
    client.define_singleton_method(:playwright_available?) { true }
    status = Status.new(false, 9)
    received = nil
    capture = lambda do |env, *command|
      received = [env, command]
      ["fanbox out\n", "fanbox err\n", status]
    end

    result = with_stubbed_capture(capture) do
      client.send(:fetch_post_payload_with_playwright, "https://creator.fanbox.cc/posts/42", "42")
    end

    assert_nil result
    assert_equal({ "FANBOX_COOKIE_HEADER" => "FANBOXSESSID=dummy" }, received[0])
    assert_equal [
      "node", FetchImages::Clients::Fanbox::PLAYWRIGHT_SCRIPT,
      "--url", "https://creator.fanbox.cc/posts/42",
      "--post-id", "42", "--browser", "firefox"
    ], received[1][0...-2]
    assert_includes messages, "Fanbox post=42: trying Playwright fallback (browser=firefox)"
    assert_includes messages, "Fanbox post=42: Playwright stdout: fanbox out"
    assert_includes messages, "Fanbox post=42: Playwright stderr: fanbox err"
    assert_includes messages, "Fanbox post=42: Playwright fallback failed with exit=9"
  end

  def test_myfans_keeps_node_arguments_and_empty_failure_fallback
    messages = []
    client = FetchImages::Clients::Myfans.new(
      cookie_header: "myfans_session=dummy",
      logger: ->(message) { messages << message },
      playwright: true,
      playwright_browser: "webkit"
    )
    client.define_singleton_method(:resolve_node_binary) { "node-test" }
    status = Status.new(false, 6)
    received = nil
    capture = lambda do |env, *command|
      received = [env, command]
      ["myfans out\n", "myfans err\n", status]
    end

    result = with_stubbed_capture(capture) do
      client.send(:fetch_media_urls_with_playwright, "https://myfans.jp/posts/42")
    end

    assert_equal({ videos: [], images: [] }, result)
    assert_equal({ "MYFANS_COOKIE_HEADER" => "myfans_session=dummy" }, received[0])
    assert_equal [
      "node-test", FetchImages::Clients::Myfans::PLAYWRIGHT_SCRIPT,
      "--url", "https://myfans.jp/posts/42", "--browser", "webkit"
    ], received[1][0...-2]
    assert_includes messages, "MyFans Playwright: trying fallback (browser=webkit)"
    assert_includes messages, "MyFans Playwright stdout: myfans out"
    assert_includes messages, "MyFans Playwright stderr: myfans err"
    assert_includes messages, "MyFans Playwright: fallback failed with exit=6"
  end

  private

  def with_stubbed_capture(capture)
    original = Open3.method(:capture3)
    Open3.define_singleton_method(:capture3, capture)
    yield
  ensure
    Open3.define_singleton_method(:capture3, original)
  end
end
