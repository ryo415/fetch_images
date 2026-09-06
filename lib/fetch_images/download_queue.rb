# frozen_string_literal: true

require "uri"
require "thread"

module FetchImages
  class DownloadQueue
    def initialize(input:, output:, &download)
      @input, @download = input, download
      @reporter = Reporter.new(output: output)
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
            code = @download.call(site, url)
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
        @input.each_line do |line|
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
