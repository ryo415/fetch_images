# frozen_string_literal: true

module FetchImages
  class Reporter
    def initialize(output:, error: output, prefixed: false)
      @output, @error, @prefixed = output, error, prefixed
    end

    def message(text)
      write(@output, text, @prefixed ? "RESULT" : nil)
    end

    def warning(text)
      write(@error, text, @prefixed ? "ERROR" : nil)
    end

    def event(status, text)
      write(@output, text, status.to_s.upcase)
    end

    def result(url, result, dry_run:)
      text = if dry_run
               "Dry run: would download #{result.planned.length} file(s) from #{url}"
             elsif result.downloaded.any?
               "Downloaded #{result.downloaded.length} file(s) from #{url}"
             elsif result.skipped.any?
               "Skipped #{result.skipped.length} existing file(s) for #{url}"
             else
               "No downloadable files found for #{url}"
             end
      message(text)
    end

    private

    def write(io, text, prefix)
      unless prefix
        io.puts(text)
        return
      end

      text.to_s.each_line { |line| io.puts("#{format('%-9s', "[#{prefix}]")}#{line.chomp}") }
    end
  end
end
