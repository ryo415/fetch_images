# frozen_string_literal: true

require "json"
require "fileutils"
require "tempfile"

module FetchImages
  class Settings
    SITES = %w[fantia fanbox myfans].freeze
    attr_reader :path

    def initialize
      root = ENV["XDG_CONFIG_HOME"].to_s
      root = File.join(Dir.home, ".config") if root.empty?
      @path = File.join(File.expand_path(root), "fetch_images", "config.json")
    end

    def for_site(site)
      read.fetch(site, {})
    end

    def update(site, values)
      raise ValidationError, "Unknown site: #{site}" unless SITES.include?(site)

      directory = File.dirname(path)
      FileUtils.mkdir_p(directory, mode: 0o700)
      File.chmod(0o700, directory)
      # Serialize updates from separate auth/config commands.
      File.open("#{path}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
        lock.flock(File::LOCK_EX)
        data = read
        data[site] = data.fetch(site, {}).merge(values).reject { |_, value| value.nil? }
        validate(data)
        Tempfile.create(["settings", ".json"], directory) do |file|
          file.chmod(0o600)
          file.write(JSON.pretty_generate(data) + "\n")
          file.flush
          file.fsync
          File.rename(file.path, path)
        end
      end
    rescue SystemCallError
      raise ValidationError, "Cannot write settings: #{path}"
    end

    private

    def read
      return {} unless File.exist?(path)

      data = JSON.parse(File.read(path))
      validate(data)
      data
    rescue JSON::ParserError, SystemCallError
      raise ValidationError, "Cannot read settings JSON: #{path}"
    end

    def validate(data)
      valid = data.is_a?(Hash) && data.all? do |site, values|
        SITES.include?(site) && values.is_a?(Hash) && values.all? do |key, value|
          case key
          when "cookie", "output" then value.is_a?(String) && !value.strip.empty? && !value.match?(/[\r\n\x00]/)
          when "playwright" then [true, false].include?(value)
          when "browser" then %w[chromium firefox webkit].include?(value)
          else false
          end
        end
      end
      raise ValidationError, "Invalid settings format: #{path}" unless valid

    end
  end
end
