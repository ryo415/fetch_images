# frozen_string_literal: true

require "open3"
require "rbconfig"
require_relative "test_helper"

class SiteDefinitionsTest < Minitest::Test
  HELP_CASES = {
    %w[--help] => ["Usage: fetch_images <subcommand>", "Subcommands:"],
    %w[fantia --help] => ["Usage: fetch_images fantia", "--fantia-password PASSWORD"],
    %w[fanbox --help] => ["Usage: fetch_images fanbox", "--[no-]fanbox-playwright"],
    %w[myfans --help] => ["Usage: fetch_images myfans", "--myfans-playwright-browser NAME"],
    %w[auth --help] => ["Usage: fetch_images auth", "--clear"],
    %w[config --help] => ["Usage: fetch_images config", "--[no-]playwright"],
    %w[queue --help] => ["Usage: fetch_images queue", "--log-file PATH"]
  }.freeze

  def capture_cli(args)
    Dir.mktmpdir("fetch-images-cli-test") do |dir|
      env = ENV.keys.grep(/\A(?:FANTIA|FANBOX|MYFANS)_/).to_h { |key| [key, nil] }
      env["XDG_CONFIG_HOME"] = dir
      env["RUBYOPT"] = nil
      env["RUBYLIB"] = nil
      Open3.capture3(env, RbConfig.ruby, File.expand_path("../bin/fetch_images", __dir__), *args)
    end
  end

  def test_cli_keeps_definition_constant_aliases
    assert_same FetchImages::SiteDefinitions::COMMANDS, FetchImages::CLI::COMMANDS
    assert_same FetchImages::SiteDefinitions::COMMON_OPTION_DEFINITIONS,
                FetchImages::CLI::COMMON_OPTION_DEFINITIONS
  end

  def test_all_command_help_remains_available_in_a_clean_environment
    HELP_CASES.each do |args, expected_fragments|
      out, err, status = capture_cli(args)

      assert status.success?, "#{args.join(' ')} failed: #{err}"
      expected_fragments.each { |fragment| assert_includes out, fragment }
    end
  end

  def test_fanbox_help_keeps_manual_json_and_playwright_flags
    out, err, status = capture_cli(%w[fanbox --help])

    assert status.success?, err
    assert_includes out, "--fanbox-post-info-json PATH"
    assert_includes out, "--[no-]fanbox-playwright"
  end

  def test_input_errors_keep_messages_and_exit_statuses
    cases = {
      [] => "Subcommand is required: choose one of fantia, fanbox, myfans",
      ["unknown"] => "Subcommand is required: choose one of fantia, fanbox, myfans",
      ["fantia", "--fantia-session", "dummy"] => "At least one URL is required",
      ["fanbox", "https://creator.fanbox.cc/posts/1"] =>
        "fanbox requires one of: --fanbox-session, --fanbox-cookie, or --fanbox-post-info-json",
      ["queue", "https://fantia.jp/posts/1"] =>
        "queue reads URLs from standard input; do not pass URL arguments"
    }

    cases.each do |args, expected_error|
      _out, err, status = capture_cli(args)

      assert_equal 1, status.exitstatus, args.inspect
      assert_includes err, expected_error, args.inspect
    end
  end
end
