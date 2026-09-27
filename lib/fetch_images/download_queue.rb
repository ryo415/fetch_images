# frozen_string_literal: true

require "uri"
require "thread"
require "reline"

module FetchImages
  class DownloadQueue
    class LineEditor
      def readline
        Reline.readline("", false)
      end

      def redisplay
        editor = Reline.line_editor
        editor.send(:clear_rendered_screen_cache)
        editor.rerender
      end
    end

    class InteractiveOutput
      CLEAR_LINE = "\r\e[2K"

      def initialize(output:, line_editor:)
        @output, @line_editor = output, line_editor
        @writing = Mutex.new
        @reading = false
      end

      def readline
        @reading = true
        @line_editor.readline
      ensure
        @reading = false
      end

      def puts(text)
        @writing.synchronize do
          @output.write(CLEAR_LINE) if @reading
          @output.puts(text)
          @line_editor.redisplay if @reading
        end
      end
    end

    def initialize(input:, output:, interactive: nil, line_editor: LineEditor.new, &download)
      @input, @download = input, download
      interactive = input.tty? && output.tty? if interactive.nil?
      @terminal = InteractiveOutput.new(output: output, line_editor: line_editor) if interactive
      @reporter = Reporter.new(output: @terminal || output)
    end

    def run
      jobs = Queue.new
      failed = []
      invalid = false
      @reporter.event(:info, "Paste post URLs, one per line. :quit / Ctrl+D finishes after queued downloads.")
      worker = Thread.new do
        while (job = jobs.pop)
          site, url = job
          @reporter.event(:start, "#{url}")
          begin
            code = @download.call(site, url, @terminal)
          rescue StandardError
            code = 1
          end
          if code == 0
            @reporter.event(:done, "#{url}")
          else
            failed << url
            @reporter.event(:fail, "#{url} (check Cookie/access or download log)")
          end
        end
      end
      begin
        each_input_line do |line|
          url = line.strip
          break if url == ":quit"
          next if url.empty?

          site = site_for(url)
          if site
            @reporter.event(:queue, "#{url}")
            jobs << [site, url]
          else
            invalid = true
            @reporter.event(:error, "Unsupported post URL: #{url}")
          end
        end
      ensure
        jobs << nil
      end
      worker.value
      unless failed.empty?
        @reporter.event(:info, "Failed URLs (paste the URL again to retry):")
        failed.each { |url| @reporter.event(:retry, "#{url}") }
      end
      failed.empty? && !invalid ? 0 : 1
    ensure
      if worker&.alive?
        worker.kill
        worker.join
      end
    end

    private

    def each_input_line
      return @input.each_line { |line| yield line } unless @terminal

      while (line = @terminal.readline)
        yield line
      end
    end

    def site_for(url)
      uri = URI.parse(url)
      return nil unless %w[http https].include?(uri.scheme) && !uri.userinfo

      host, path = uri.host.to_s.downcase, uri.path
      if %w[fantia.jp www.fantia.jp].include?(host) && path.match?(%r{\A/(?:fanclubs/\d+/)?posts/\d+/?\z})
        "fantia"
      elsif ((host == "www.fanbox.cc" && path.match?(%r{\A/@[\w-]+/posts/\d+/?\z})) ||
             (host.match?(/\A[\w-]+\.fanbox\.cc\z/) && path.match?(%r{\A/posts/\d+/?\z})))
        "fanbox"
      elsif %w[myfans.jp www.myfans.jp].include?(host) && path.match?(%r{\A/(?:[^/]+/)?posts/[^/]+/?\z})
        "myfans"
      end
    rescue URI::InvalidURIError
      nil
    end
  end
end
