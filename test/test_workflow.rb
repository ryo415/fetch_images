# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require "timeout"
require_relative "../lib/fetch_images"

class WorkflowTest < Minitest::Test
  class CapturingCLI < FetchImages::CLI
    attr_reader :captured
    attr_accessor :result

    private

    def build_client(_logger)
      @captured = %i[myfans_cookie myfans_session myfans_playwright output].to_h { |key| [key, option(key)] }
      result = @result || FetchImages::DownloadResult.new(planned: ["media"], downloaded: ["saved"])
      client = Object.new
      client.define_singleton_method(:supports_url?) { |_| true }
      client.define_singleton_method(:download_images) { |*_, **_| result }
      client
    end
  end

  def setup
    @dir = Dir.mktmpdir("fetch-images-test")
    @old_env = ENV.to_h
    ENV.keys.grep(/\A(?:FANTIA|FANBOX|MYFANS)_/).each { |key| ENV.delete(key) }
    ENV["XDG_CONFIG_HOME"] = @dir
  end

  def teardown
    ENV.replace(@old_env)
    FileUtils.remove_entry(@dir)
  end

  def run_cli(args, input = "")
    out, err = StringIO.new, StringIO.new
    code = FetchImages::CLI.new(args, input: StringIO.new(input), output: out, error: err).run
    [code, out.string, err.string]
  end

  def test_register_cookie_without_echo_and_retain_site_settings
    assert_equal 0, run_cli(%w[config myfans --output ./pictures --playwright])[0]
    code, out, err = run_cli(%w[auth myfans], "Cookie: myfans_session=private-value; foo=bar\n")
    assert_equal 0, code
    refute_includes out + err, "private-value"
    path = File.join(@dir, "fetch_images", "config.json")
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(path)).mode & 0o777
    settings = JSON.parse(File.read(path)).fetch("myfans")
    assert_equal "myfans_session=private-value; foo=bar", settings["cookie"]
    assert_equal File.expand_path("pictures"), settings["output"]
    assert_equal true, settings["playwright"]
    assert_equal 0, run_cli(%w[auth myfans --clear])[0]
    settings = JSON.parse(File.read(path)).fetch("myfans")
    refute settings.key?("cookie")
    assert_equal true, settings["playwright"]
  end

  def test_bad_cookie_and_corrupt_config_are_not_overwritten
    assert_equal 1, run_cli(%w[auth myfans], "not-a-cookie\n")[0]
    path = File.join(@dir, "fetch_images", "config.json")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "broken-secret")
    code, out, err = run_cli(%w[auth myfans], "session=value\n")
    assert_equal 1, code
    refute_includes out + err, "broken-secret"
    assert_equal "broken-secret", File.read(path)
  end

  def test_saved_settings_are_used_by_normal_cli
    run_cli(%w[auth fanbox], "FANBOXSESSID=saved\n")
    run_cli(["config", "fanbox", "--output", File.join(@dir, "images"), "--playwright"])
    payload = File.join(@dir, "post.json")
    File.write(payload, JSON.generate({ "body" => { "body" => { "images" => [{ "originalUrl" => "https://example.com/a.jpg" }] } } }))
    code, out, err = run_cli(["fanbox", "--dry-run", "--fanbox-post-info-json", payload, "https://creator.fanbox.cc/posts/1"])
    assert_equal 0, code, err
    assert_includes out, "1 file(s)"
    assert Dir.exist?(File.join(@dir, "images"))
  end

  def test_auth_sources_replace_lower_priority_credentials
    run_cli(%w[auth myfans], "myfans_session=saved\n")
    run_cli(["config", "myfans", "--output", @dir, "--playwright"])
    ENV["MYFANS_SESSION"] = "environment"
    cli = CapturingCLI.new(["myfans", "https://myfans.jp/posts/1"], output: StringIO.new)
    assert_equal 0, cli.run
    assert_nil cli.captured[:myfans_cookie]
    assert_equal "environment", cli.captured[:myfans_session]
    assert_equal true, cli.captured[:myfans_playwright]

    cli = CapturingCLI.new(["myfans", "--myfans-cookie", "session=explicit", "--no-myfans-playwright", "https://myfans.jp/posts/1"], output: StringIO.new)
    assert_equal 0, cli.run
    assert_nil cli.captured[:myfans_session]
    assert_equal "session=explicit", cli.captured[:myfans_cookie]
    assert_equal false, cli.captured[:myfans_playwright]
  end

  def test_queue_flags_partial_and_empty_results_as_failure
    run_cli(%w[auth myfans], "myfans_session=saved\n")
    run_cli(["config", "myfans", "--output", @dir])
    [FetchImages::DownloadResult.new(planned: %w[a b], downloaded: ["a"]),
     FetchImages::DownloadResult.new].each do |result|
      cli = CapturingCLI.new(["myfans", "https://myfans.jp/posts/1"], output: StringIO.new, error: StringIO.new, strict_results: true)
      cli.result = result
      assert_equal 1, cli.run
    end
  end

  def test_queue_cli_runs_saved_configuration_with_offline_fanbox_payload
    run_cli(["config", "fanbox", "--output", @dir])
    payload = File.join(@dir, "payload.json")
    File.write(payload, JSON.generate({ "body" => { "body" => { "images" => [{ "originalUrl" => "https://example.com/a.jpg" }] } } }))
    ENV["FANBOX_POST_INFO_JSON"] = payload
    code, out, err = run_cli(%w[queue --dry-run], "https://creator.fanbox.cc/posts/1\n")
    assert_equal 0, code, err
    assert_includes out, "1 file(s)"
    assert_includes out, "[DONE]"
  end

  def test_invalid_config_options_do_not_write_settings
    assert_equal 1, run_cli(%w[config fantia --playwright])[0]
    assert_equal 1, run_cli(%w[config myfans --browser invalid])[0]
    refute File.exist?(File.join(@dir, "fetch_images", "config.json"))
  end

  def test_invalid_output_path_does_not_corrupt_existing_settings
    run_cli(%w[auth myfans], "session=saved\n")
    path = File.join(@dir, "fetch_images", "config.json")
    original = File.read(path)
    assert_equal 1, run_cli(["config", "myfans", "--output", "bad\npath"])[0]
    assert_equal original, File.read(path)
    assert_equal 0, run_cli(%w[config myfans])[0]
  end

  def test_queue_processes_mixed_sites_and_reports_failures
    output = StringIO.new
    visited = []
    queue = FetchImages::DownloadQueue.new(input: StringIO.new("https://fantia.jp/posts/1\nhttps://myfans.jp/posts/2\n:quit\n"), output: output) do |site, url|
      visited << [site, url]
      site == "fantia" ? 1 : 0
    end
    assert_equal 1, queue.run
    assert_equal ["fantia", "myfans"], visited.map(&:first)
    assert_includes output.string, "https://fantia.jp/posts/1"
  end

  def test_queue_accepts_next_url_while_downloading_and_drains_on_eof
    reader, writer = IO.pipe
    started, release, accepted = Queue.new, Queue.new, Queue.new
    output = StringIO.new
    output.define_singleton_method(:puts) do |message|
      accepted << true if message.include?("https://myfans.jp/posts/2")
      super(message)
    end
    visited = []
    queue = FetchImages::DownloadQueue.new(input: reader, output: output) do |_site, url|
      visited << url
      if visited.length == 1
        started << true
        release.pop
      end
      0
    end
    thread = Thread.new { queue.run }
    writer.puts("https://fantia.jp/posts/1")
    Timeout.timeout(3) { started.pop }
    writer.puts("https://myfans.jp/posts/2")
    Timeout.timeout(3) { accepted.pop }
    writer.close
    release << true
    assert_equal 0, Timeout.timeout(3) { thread.value }
    assert_equal 2, visited.length
  ensure
    release << true if release
    writer&.close unless writer&.closed?
    thread&.join(1)
    reader&.close
  end

  def test_queue_rejects_other_hosts_and_profile_urls
    visited = []
    queue = FetchImages::DownloadQueue.new(input: StringIO.new("https://evil.test/https://fantia.jp/posts/1\nhttps://myfans.jp/profile\n"), output: StringIO.new) do |site, url|
      visited << [site, url]
      0
    end
    assert_equal 1, queue.run
    assert_empty visited
  end
end
