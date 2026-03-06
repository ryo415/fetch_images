# frozen_string_literal: true

module FetchImages
  module Support
    module_function

    def normalize_escaped_text(text)
      text.to_s
          .gsub("\\/", "/")
          .gsub(/\\u002f/i, "/")
          .gsub(/\\u003a/i, ":")
          .gsub(/\\u0026/i, "&")
    end

    def safe_utf8(value)
      value.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
    rescue StandardError
      value.to_s.force_encoding("UTF-8")
    end

    def resolve_executable(*names, env_key: nil)
      from_env = env_key ? ENV[env_key].to_s.strip : ""
      return from_env unless from_env.empty?

      path_entries = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR)
      names.each do |name|
        path_entries.each do |dir|
          next if dir.to_s.empty?

          full_path = File.join(dir, name)
          return full_path if File.file?(full_path) && File.executable?(full_path)
        end
      end

      nil
    end
  end
end
