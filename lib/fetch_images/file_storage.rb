# frozen_string_literal: true

require "cgi"
require "fileutils"
require "tempfile"
require "uri"

begin
  require "unicode_normalize"
rescue LoadError
  # The optional unicode_normalize default gem may not be available in
  # minimal Ruby distributions. Filename sanitisation gracefully falls back
  # when it cannot be loaded.
end

module FetchImages
  class FileStorage
    def build_filename(image_url, index)
      uri = URI(image_url)
      name = File.basename(CGI.unescape(uri.path.to_s))
      name = "image_#{index}" if name.nil? || name.empty?
      name = sanitize_filename(name)
      format("%03d_%s", index, name)
    end

    def slugify(value)
      normalized = value.to_s
      normalized = normalized.unicode_normalize(:nfkd) if normalized.respond_to?(:unicode_normalize)
      normalized = normalized.strip
      normalized = normalized.gsub(/\s+/, "-")
      normalized = normalized.gsub(/[^a-zA-Z0-9._-]/, "")
      normalized.empty? ? "post" : normalized
    end

    def sanitize_directory_name(name, fallback: "post")
      sanitized = name.to_s
      sanitized = sanitized.unicode_normalize(:nfkc) if sanitized.respond_to?(:unicode_normalize)
      sanitized = sanitized.delete("\u0000")
      sanitized = sanitized.gsub(/[[:cntrl:]]+/, " ")
      sanitized = sanitized.gsub(/[\\\/:*?"<>|]/, "_")
      sanitized = sanitized.gsub(/\s+/, " ").strip
      sanitized = sanitized.gsub(/\A\.+/, "").gsub(/\.+\z/, "")
      sanitized.empty? ? fallback : sanitized
    end

    def sanitize_filename(filename)
      sanitized = filename.gsub(File::SEPARATOR, "_").delete("\u0000")
      sanitized = sanitized.gsub(/\.+\z/, "")
      sanitized.empty? ? "image" : sanitized
    end

    def ensure_extension(path, content_type)
      return path unless File.extname(path).empty?

      ext = case content_type.to_s.downcase
            when /image\/jpe?g/
              ".jpg"
            when /image\/png/
              ".png"
            when /image\/webp/
              ".webp"
            when /image\/gif/
              ".gif"
            when /image\/bmp/
              ".bmp"
            when /image\/avif/
              ".avif"
            when /video\/mp4/
              ".mp4"
            when /video\/webm/
              ".webm"
            when /application\/vnd\.apple\.mpegurl/, /application\/x-mpegurl/
              ".m3u8"
            else
              ".img"
            end
      "#{path}#{ext}"
    end

    def save_response(path, response)
      save_path = ensure_extension(path, response["Content-Type"])
      FileUtils.mkdir_p(File.dirname(save_path))

      Tempfile.create([File.basename(save_path), ".part"], File.dirname(save_path), binmode: true) do |file|
        response.read_body { |chunk| file.write(chunk) }
        file.flush
        file.close

        File.delete(save_path) if File.exist?(save_path)
        File.rename(file.path, save_path)
      end

      save_path
    end

    def existing_download_path(path)
      return path if File.exist?(path)
      return nil unless File.extname(path).empty?

      Dir.glob("#{path}.*").sort.first
    end
  end
end
