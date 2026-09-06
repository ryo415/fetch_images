# frozen_string_literal: true

module FetchImages
  # Combines saved settings and environment values, then accepts explicit options.
  # Authentication switches source as a group to avoid mixing credentials.
  class OptionResolver
    DEFAULT_OUTPUT_DIR = File.expand_path("downloads")

    def self.build_credentials(email, password)
      return nil if email.to_s.empty? || password.to_s.empty?

      { email: email, password: password }
    end

    def initialize(site:, commands:, settings: Settings.new, env: ENV)
      @explicit_auth = {}
      @values = {
        output: DEFAULT_OUTPUT_DIR, overwrite: false, dry_run: false,
        verbose: false, log_file: nil
      }
      apply_saved(site, settings.for_site(site)) if site
      commands.each do |name, command|
        defaults = command.fetch(:env_defaults, {})
        if defaults.any? { |key, variable| authentication_keys(name).include?(key) && !env[variable].to_s.strip.empty? }
          clear_authentication(name)
        end
        defaults.each do |key, variable|
          @values[key] = env[variable] unless env[variable].to_s.strip.empty?
        end
        command.fetch(:option_defaults, {}).each do |key, value|
          @values[key] = value unless @values.key?(key)
        end
      end
    end

    def set_option(key, value)
      site = key.to_s.split("_").first
      if authentication_keys(site).include?(key) && !@explicit_auth[site]
        clear_authentication(site)
        @explicit_auth[site] = true
      end
      @values[key] = value
    end

    def option(key)
      @values[key]
    end

    def option_present?(key)
      !option(key).to_s.strip.empty?
    end

    private

    def apply_saved(site, saved)
      @values[:output] = saved["output"] if saved.key?("output")
      @values["#{site}_cookie".to_sym] = saved["cookie"]
      @values["#{site}_playwright".to_sym] = saved["playwright"] if saved.key?("playwright")
      @values["#{site}_playwright_browser".to_sym] = saved["browser"] if saved.key?("browser")
    end

    def authentication_keys(site)
      %w[cookie session email password post_info_json].map { |name| "#{site}_#{name}".to_sym }
    end

    def clear_authentication(site)
      authentication_keys(site).each { |key| @values[key] = nil }
    end
  end
end
