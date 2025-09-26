# frozen_string_literal: true

require 'nokogiri'
require 'uri'

module Fantia
  class Authenticator
    SIGN_IN_URI = URI('https://fantia.jp/sessions/signin')

    def initialize(client:, email:, password:, otp: nil, otp_provider: nil, logger: nil)
      @client = client
      @email = email
      @password = password
      @otp = otp
      @otp_provider = otp_provider
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
        follow_redirect(response, login_uri)
        return true
      end

      body = response.body
      doc = Nokogiri::HTML(body)
      if (two_factor_form = locate_two_factor_form(doc))
        log('Fantia requested a two-factor authentication code')
        complete_two_factor_challenge(two_factor_form, login_uri)
        return true if @authenticated

        message = extract_two_factor_error(doc)
        raise "Two-factor authentication failed: #{message}"
      end

      message = extract_login_error(doc)
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

    def locate_two_factor_form(doc)
      doc.css('form[action][method="post"]').find do |candidate|
        candidate.css('input[name]').any? { |input| input['name'].to_s.downcase.include?('otp') }
      end
    end

    def build_login_uri(form)
      action = form['action'].to_s.strip
      action.empty? ? SIGN_IN_URI : URI.join(SIGN_IN_URI, action)
    end

    def complete_two_factor_challenge(form, login_uri)
      otp_code = obtain_otp
      raise 'A two-factor authentication code is required. Provide one with --otp or --otp-prompt.' if otp_code.to_s.strip.empty?

      target_uri = form['action'].to_s.strip
      target_uri = target_uri.empty? ? login_uri : URI.join(login_uri, target_uri)

      payload = build_two_factor_payload(form, otp_code)
      response = @client.post_form(target_uri, payload, referer: login_uri)

      if response.is_a?(Net::HTTPRedirection)
        follow_redirect(response, target_uri)
        return
      end

      doc = Nokogiri::HTML(response.body)
      if locate_two_factor_form(doc)
        message = extract_two_factor_error(doc)
        raise "Two-factor authentication failed: #{message}"
      end

      @authenticated = true
    end

    def build_two_factor_payload(form, otp_code)
      payload = {}

      form.css('input[name]').each do |input|
        type = input['type']&.downcase
        next if %w[submit button image].include?(type)

        name = input['name']
        next if name.to_s.empty?

        payload[name] = if name.downcase.include?('otp')
                          otp_code
                        else
                          input['value'] || ''
                        end
      end

      payload
    end

    def follow_redirect(response, base_uri)
      location = response['location']
      @client.get(URI.join(base_uri, location)) if location
      @authenticated = true
    end

    def obtain_otp
      return @otp unless @otp.to_s.strip.empty?

      return unless @otp_provider

      @otp = @otp_provider.call
    end

    def extract_login_error(doc)
      error = doc.at_css('.alert, .alert-danger, .error, .errors')&.text&.strip
      return error unless error.nil? || error.empty?

      'Invalid email or password.'
    end

    def extract_two_factor_error(doc)
      error = doc.at_css('.alert, .alert-danger, .error, .errors')&.text&.strip
      return error unless error.nil? || error.empty?

      'Invalid or expired two-factor authentication code.'
    end

    def log(message)
      @logger&.call(message)
    end
  end
end
