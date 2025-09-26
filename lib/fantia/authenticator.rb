# frozen_string_literal: true

require 'nokogiri'
require 'uri'

module Fantia
  class Authenticator
    SIGN_IN_URI = URI('https://fantia.jp/sign_in')

    def initialize(client:, email:, password:, logger: nil)
      @client = client
      @email = email
      @password = password
      @logger = logger
      @authenticated = false
    end

    def authenticate!
      return true if @authenticated

      ensure_credentials!
      log('Authenticating with Fantia')

      html = @client.get(SIGN_IN_URI)
      doc = Nokogiri::HTML(html)
      form = locate_login_form(doc)
      raise 'Unable to locate sign-in form on Fantia.' unless form

      login_uri = build_login_uri(form)
      token = form.at_css('input[name="authenticity_token"]')&.[]('value')
      raise 'Unable to locate authenticity token for sign-in.' unless token

      payload = {
        'authenticity_token' => token,
        'user[email]' => @email,
        'user[password]' => @password,
        'user[remember_me]' => '0'
      }

      response = @client.post_form(login_uri, payload, referer: SIGN_IN_URI)

      if response.is_a?(Net::HTTPRedirection)
        location = response['location']
        @client.get(URI.join(login_uri, location)) if location
        @authenticated = true
        return true
      end

      body = response.body
      message = extract_login_error(body)
      raise "Login failed: #{message}"
    end

    private

    def ensure_credentials!
      if @email.to_s.strip.empty? || @password.to_s.strip.empty?
        raise ArgumentError, 'Both email and password are required to authenticate with Fantia.'
      end
    end

    def locate_login_form(doc)
      doc.css('form[action][method="post"]').find do |candidate|
        candidate.at_css('input[name="user[email]"]') &&
          candidate.at_css('input[name="user[password]"]')
      end
    end

    def build_login_uri(form)
      action = form['action'].to_s.strip
      action.empty? ? SIGN_IN_URI : URI.join(SIGN_IN_URI, action)
    end

    def extract_login_error(body)
      doc = Nokogiri::HTML(body)
      error = doc.at_css('.alert, .alert-danger, .error, .errors')&.text&.strip
      return error unless error.nil? || error.empty?

      'Invalid email or password.'
    end

    def log(message)
      @logger&.call(message)
    end
  end
end
