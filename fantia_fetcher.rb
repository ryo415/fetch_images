#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'uri'
require 'net/http'
require 'fileutils'
require 'io/console'

begin
  require 'nokogiri'
rescue LoadError
  warn 'This script requires the nokogiri gem. Install it with `gem install nokogiri`.'
  exit 1
end

class FantiaImageFetcher
  DEFAULT_USER_AGENT = 'Mozilla/5.0 (X11; Linux x86_64) '
                       'AppleWebKit/537.36 (KHTML, like Gecko) '
                       'Chrome/119.0.0.0 Safari/537.36'

  def initialize(url:, output_dir:, cookie: nil, verbose: false, email: nil, password: nil)
    @url = URI.parse(url)
    @output_dir = output_dir
    @manual_cookie = cookie
    @verbose = verbose
    @email = email
    @password = password
    @authenticated = false
    @cookie_jar = {}
  end

  def run
    authenticate_if_needed
    validate_url!
    html = fetch(@url)
    doc = Nokogiri::HTML(html)
    image_urls = extract_image_urls(doc)

    if image_urls.empty?
      warn 'No images found in the supplied article.'
      return
    end

    FileUtils.mkdir_p(@output_dir)
    download_images(image_urls)
  end

  private

  def validate_url!
    unless %w[http https].include?(@url.scheme)
      raise ArgumentError, 'URL must start with http:// or https://'
    end

    return if @url.host&.include?('fantia.jp')

    raise ArgumentError, 'The provided URL does not appear to be a Fantia article.'
  end

  def http_client_for(uri)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.read_timeout = 60
    http.open_timeout = 15
    http
  end

  def fetch(uri, depth = 0)
    raise "Too many redirects while fetching #{uri}" if depth > 10

    request = Net::HTTP::Get.new(uri)
    apply_default_headers(request, uri)
    http = http_client_for(uri)

    log("Fetching #{uri}")
    response = http.request(request)
    store_cookies(response)

    case response
    when Net::HTTPRedirection
      location = response['location']
      raise "Redirect missing location header for #{uri}" unless location

      new_uri = URI.join(uri, location)
      fetch(new_uri, depth + 1)
    when Net::HTTPSuccess
      response.body
    else
      raise "Failed to fetch #{uri} (status: #{response.code})"
    end
  end

  def extract_image_urls(doc)
    urls = []

    doc.css('img').each do |img|
      candidate = select_best_image_source(img)
      next unless candidate

      begin
        absolute = URI.join(@url, candidate)
      rescue URI::Error
        log("Skipping invalid image URL: #{candidate}")
        next
      end

      urls << absolute
    end

    doc.css('a[data-download], a[download]').each do |link|
      href = link['href']
      next unless href

      begin
        absolute = URI.join(@url, href)
      rescue URI::Error
        next
      end

      urls << absolute if image_extension?(absolute)
    end

    urls.uniq
  end

  def select_best_image_source(img)
    %w[data-src data-original data-url data-image data-srcset data-original-src srcset src].each do |attr|
      value = img[attr]
      next unless value

      return highest_resolution_from_srcset(value) if attr.include?('srcset')
      return value unless value.strip.empty?
    end

    nil
  end

  def highest_resolution_from_srcset(srcset)
    candidates = srcset.split(',').filter_map do |entry|
      url, descriptor = entry.strip.split(/\s+/, 2)
      next if url.nil? || url.empty?

      weight = descriptor.to_s[/[0-9]+(?:\.[0-9]+)?/]

      score = if descriptor&.include?('w')
                weight ? weight.to_i : 0
              elsif descriptor&.include?('x')
                weight ? weight.to_f : 1
              else
                1
              end

      [url, score]
    end

    candidates.max_by { |(_, score)| score }&.first || candidates.dig(0, 0)
  end

  def image_extension?(uri)
    File.extname(uri.path).match?(/\A\.(png|jpe?g|gif|webp|bmp|svg)\z/i)
  end

  def download_images(urls)
    urls.each_with_index do |uri, index|
      filename = filename_for(uri, index)
      target = File.join(@output_dir, filename)
      log("Downloading #{uri} -> #{target}")
      download_single_image(uri, target)
    end
  end

  def download_single_image(uri, target, depth = 0)
    raise "Too many redirects while downloading #{uri}" if depth > 5

    request = Net::HTTP::Get.new(uri)
    apply_default_headers(request, uri)

    http_client_for(uri).request(request) do |response|
      store_cookies(response)

      case response
      when Net::HTTPSuccess
        File.open(target, 'wb') do |file|
          response.read_body { |chunk| file.write(chunk) }
        end
      when Net::HTTPRedirection
        location = response['location']
        raise "Redirect missing location header for #{uri}" unless location

        new_uri = URI.join(uri, location)
        download_single_image(new_uri, target, depth + 1)
      else
        warn "Failed to download #{uri} (status: #{response.code})"
      end
    end
  end

  def filename_for(uri, index)
    base = File.basename(uri.path)
    base = "image_#{index + 1}" if base.nil? || base.empty? || base == '/'

    if File.exist?(File.join(@output_dir, base))
      ext = File.extname(base)
      stem = File.basename(base, ext)
      counter = 1
      new_base = nil

      loop do
        new_base = format('%s_%02d%s', stem, counter, ext)
        break unless File.exist?(File.join(@output_dir, new_base))

        counter += 1
      end

      base = new_base
    end

    base
  end

  def log(message)
    warn(message) if @verbose
  end

  def authenticate_if_needed
    return if @authenticated
    return if @manual_cookie && !@manual_cookie.strip.empty?

    if @email.nil? && @password.nil?
      return
    elsif @email.nil? || @password.nil?
      raise ArgumentError, 'Both email and password are required to authenticate with Fantia.'
    end

    log('Authenticating with Fantia')
    sign_in_uri = URI('https://fantia.jp/sign_in')
    html = fetch(sign_in_uri)
    doc = Nokogiri::HTML(html)
    form = doc.css('form[action][method="post"]').find do |candidate|
      candidate.at_css('input[name="user[email]"]') && candidate.at_css('input[name="user[password]"]')
    end

    raise 'Unable to locate sign-in form on Fantia.' unless form

    action = form['action'].to_s.strip
    login_uri = action.empty? ? sign_in_uri : URI.join(sign_in_uri, action)
    token = form.at_css('input[name="authenticity_token"]')&.[]('value')
    raise 'Unable to locate authenticity token for sign-in.' unless token

    payload = {
      'authenticity_token' => token,
      'user[email]' => @email,
      'user[password]' => @password,
      'user[remember_me]' => '0'
    }

    response = post_form(login_uri, payload, referer: sign_in_uri)

    if response.is_a?(Net::HTTPRedirection)
      location = response['location']
      get(URI.join(login_uri, location)) if location
      @authenticated = true
      return
    end

    body = response.body
    message = extract_login_error(body)
    raise "Login failed: #{message}"
  end

  def get(uri, depth = 0)
    fetch(uri, depth)
  end

  def post_form(uri, params, referer: nil)
    request = Net::HTTP::Post.new(uri)
    apply_default_headers(request, uri)
    request['Referer'] = referer.to_s if referer
    request.set_form_data(params)

    response = http_client_for(uri).request(request)
    store_cookies(response)
    response
  end

  def apply_default_headers(request, _uri)
    request['User-Agent'] = DEFAULT_USER_AGENT
    cookie_header = combined_cookie_header
    request['Cookie'] = cookie_header if cookie_header
  end

  def combined_cookie_header
    parts = []
    parts << @manual_cookie.strip if @manual_cookie&.strip&.length&.positive?
    jar = @cookie_jar.map { |key, value| "#{key}=#{value}" }
    parts.concat(jar) unless jar.empty?
    parts.empty? ? nil : parts.join('; ')
  end

  def store_cookies(response)
    cookies = response.get_fields('set-cookie')
    return unless cookies

    cookies.each do |cookie|
      name_value = cookie.split(';', 2).first
      next unless name_value

      name, value = name_value.split('=', 2)
      next unless name

      name = name.strip
      value = value ? value.strip : ''

      if value.empty?
        @cookie_jar.delete(name)
      else
        @cookie_jar[name] = value
      end
    end
  end

  def extract_login_error(body)
    doc = Nokogiri::HTML(body)
    error = doc.at_css('.alert, .alert-danger, .error, .errors')&.text&.strip
    return error unless error.nil? || error.empty?

    'Invalid email or password.'
  end
end

options = {
  output: 'images',
  cookie: nil,
  verbose: false,
  email: nil,
  password: nil,
  password_mode: nil
}

parser = OptionParser.new do |opts|
  opts.banner = 'Usage: ruby fantia_fetcher.rb [options] ARTICLE_URL'

  opts.on('-o', '--output DIR', 'Directory to save images (default: images)') do |dir|
    options[:output] = dir
  end

  opts.on('-c', '--cookie COOKIE', 'Cookie header for authenticated requests') do |cookie|
    options[:cookie] = cookie
  end

  opts.on('-u', '--email EMAIL', 'Fantia account email address for authentication') do |email|
    options[:email] = email
  end

  opts.on('-p', '--password PASSWORD', 'Fantia account password (consider using --password-stdin)') do |password|
    options[:password] = password
  end

  opts.on('--password-stdin', 'Read the Fantia password from standard input') do
    options[:password_mode] = :stdin
  end

  opts.on('--password-prompt', 'Prompt for the Fantia password (input hidden)') do
    options[:password_mode] = :prompt
  end

  opts.on('-v', '--[no-]verbose', 'Print progress information') do |verbose|
    options[:verbose] = verbose
  end

  opts.on('-h', '--help', 'Show this help message') do
    puts opts
    exit
  end
end

parser.parse!

case options[:password_mode]
when :stdin
  input = STDIN.gets
  raise ArgumentError, 'No password provided on STDIN.' unless input

  options[:password] = input.chomp
when :prompt
  print 'Fantia password: '
  input = STDIN.noecho(&:gets)
  puts
  raise ArgumentError, 'No password provided.' unless input

  options[:password] = input.chomp
end

if ARGV.empty?
  warn parser.to_s
  exit 1
end

url = ARGV.first

begin
  fetcher = FantiaImageFetcher.new(
    url: url,
    output_dir: options[:output],
    cookie: options[:cookie],
    verbose: options[:verbose],
    email: options[:email],
    password: options[:password]
  )
  fetcher.run
rescue StandardError => e
  warn "Error: #{e.message}"
  exit 1
end
