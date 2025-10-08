# frozen_string_literal: true

module FetchImages
  module EnvLoader
    module_function

    def load_default
      load_file(default_path)
    end

    def load_file(path)
      expanded = File.expand_path(path)
      return unless File.file?(expanded)

      File.foreach(expanded, chomp: true) do |line|
        key, value = parse_line(line)
        next unless key

        ENV[key] = value unless ENV.key?(key)
      end
    end

    def default_path
      File.expand_path("../.env", __dir__)
    end

    def parse_line(line)
      stripped = line.strip
      return if stripped.empty? || stripped.start_with?("#")

      stripped = stripped.sub(/\Aexport\s+/, "")
      key, raw_value = stripped.split("=", 2)
      return unless key

      key = key.strip
      value = sanitize_value(raw_value)
      [key, value]
    end

    def sanitize_value(raw_value)
      return "" if raw_value.nil?

      trimmed = raw_value.strip
      if trimmed.match?(/\A(['"]).*\1\z/)
        trimmed[1...-1]
      else
        trimmed.split(/\s+#/, 2).first.strip
      end
    end
  end
end
