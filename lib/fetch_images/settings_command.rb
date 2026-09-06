# frozen_string_literal: true

require "io/console"
require "optparse"

module FetchImages
  class SettingsCommand
    def initialize(command, argv, input:, output:)
      @command, @argv, @input, @output = command, argv.dup, input, output
    end

    def run
      values = {}
      clear = false
      help = false
      parser = OptionParser.new do |opts|
        opts.banner = "Usage: fetch_images #{@command} <fantia|fanbox|myfans> [options]"
        if @command == "auth"
          opts.on("--clear", "Remove saved Cookie") { clear = true }
        else
          opts.on("-o", "--output DIR", "Save output directory") { |v| values["output"] = File.expand_path(v) }
          opts.on("--[no-]playwright", "Save browser fallback preference") { |v| values["playwright"] = v }
          opts.on("--browser NAME", %w[chromium firefox webkit], "chromium|firefox|webkit") { |v| values["browser"] = v }
        end
        opts.on("-h", "--help", "Show help") { help = true }
      end
      sites = parser.parse!(@argv)
      if help
        @output.puts(parser)
        return 0
      end
      site = sites.first
      raise ValidationError, parser.to_s unless sites.length == 1 && Settings::SITES.include?(site)
      if site == "fantia" && (values.key?("playwright") || values.key?("browser"))
        raise ValidationError, "Fantia does not support Playwright settings"
      end

      settings = Settings.new
      if @command == "auth"
        values["cookie"] = clear ? nil : read_cookie
        settings.update(site, values)
        @output.puts("#{site}: Cookie #{clear ? 'removed' : 'saved'} (#{settings.path})")
      elsif values.empty?
        saved = settings.for_site(site)
        @output.puts("#{site}: Cookie #{saved.key?('cookie') ? 'registered' : 'not registered'}")
        saved.reject { |key, _| key == "cookie" }.each { |key, value| @output.puts("#{key}: #{value}") }
      else
        settings.update(site, values)
        @output.puts("#{site}: settings saved (#{settings.path})")
      end
      0
    end

    private

    def read_cookie
      @output.puts("Paste Cookie header and press Enter (input hidden):")
      line = if @input.tty?
               @input.noecho(&:gets)
             else
               @input.gets
             end
      cookie = line.to_s.strip.sub(/\ACookie:\s*/i, "")
      valid = !cookie.empty? && !cookie.match?(/[\r\n\x00]/) && cookie.split(";").all? do |part|
        part.strip.match?(/\A[^\s=;:]+=[^;]*\z/)
      end
      raise ValidationError, "Invalid Cookie header; saved Cookie was not changed" unless valid

      cookie
    end
  end
end
