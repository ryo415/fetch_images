#!/usr/bin/env ruby
# frozen_string_literal: true

require 'optparse'
require 'uri'
require 'io/console'

begin
  require 'nokogiri'
rescue LoadError
  warn 'This script requires the nokogiri gem. Install it with `gem install nokogiri`.'
  exit 1
end

require_relative 'lib/fantia'

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
logger = options[:verbose] ? ->(message) { warn(message) } : nil
manual_cookie = options[:cookie]
manual_cookie = nil if manual_cookie&.strip&.empty?

client = Fantia::HttpClient.new(manual_cookie: manual_cookie, logger: logger)
extractor = Fantia::ImageExtractor.new(logger: logger)

authenticator = nil

if manual_cookie.nil?
  email = options[:email]
  password = options[:password]

  if email && password
    authenticator = Fantia::Authenticator.new(
      client: client,
      email: email,
      password: password,
      logger: logger
    )
  elsif email || password
    raise ArgumentError, 'Both email and password are required to authenticate with Fantia.'
  end
end

begin
  fetcher = Fantia::ArticleImageFetcher.new(
    url: url,
    output_dir: options[:output],
    client: client,
    extractor: extractor,
    authenticator: authenticator,
    logger: logger
  )
  fetcher.run
rescue StandardError => e
  warn "Error: #{e.message}"
  exit 1
end
