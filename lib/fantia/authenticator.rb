# frozen_string_literal: true

require 'nokogiri'
require 'uri'

module Fantia
  class Authenticator
    SIGN_IN_URI = URI('https://fantia.jp/sessions/signin')
    ACCOUNT_HOME_URI = URI('https://fantia.jp/mypage')

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
      unless form
        log("No Fantia sign-in form detected. Available forms: #{doc.css('form[action]').map { |f| f['action'] || '(self)' }.join(', ')}")
        raise 'Unable to locate sign-in form on Fantia.'
      end

      login_uri = build_login_uri(form)
      log("Located Fantia sign-in form posting to #{login_uri}")
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
        log('Fantia requested a two-factor authentication code via email')
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
      doc.css('form').find do |candidate|
        candidate.css('input').any? { |input| two_factor_input?(input) }
      end
    end

    def build_login_uri(form)
      action = form['action'].to_s.strip
      action.empty? ? SIGN_IN_URI : URI.join(SIGN_IN_URI, action)
    end

    def complete_two_factor_challenge(form, current_page_uri)
      otp_code = obtain_otp
      if otp_code.to_s.strip.empty?
        raise 'Fantia sent a two-factor authentication code via email. Provide it with --otp or run the script interactively.'
      end

      target_uri = form['action'].to_s.strip
      target_uri = target_uri.empty? ? current_page_uri : URI.join(current_page_uri, target_uri)
      log("Submitting two-factor authentication code to #{target_uri}")

      payload = build_two_factor_payload(form, otp_code)
      response = @client.post_form(target_uri, payload, referer: current_page_uri)

      if response.is_a?(Net::HTTPRedirection)
        log('Two-factor submission redirected, following next step')
        follow_redirect(response, target_uri)
        return
      end

      doc = Nokogiri::HTML(response.body)
      if locate_two_factor_form(doc)
        message = extract_two_factor_error(doc)
        raise "Two-factor authentication failed: #{message}"
      end

      log('Two-factor authentication form accepted, verifying session')
      verify_login!
    end

    def build_two_factor_payload(form, otp_code)
      payload = {}

      form.css('input[name]').each do |input|
        type = input['type']&.downcase
        next if %w[submit button image].include?(type)

        name = input['name']
        next if name.to_s.empty?

        payload[name] = if two_factor_input?(input)
                          otp_code
                        else
                          case name
                          when 'user[email]'
                            @email
                          when 'user[password]'
                            @password
                          else
                            input['value'] || ''
                          end
                        end
      end

      payload
    end

    def two_factor_input?(input)
      type = input['type']&.downcase
      return false if %w[hidden submit button image].include?(type)

      name = input['name'].to_s
      autocomplete = input['autocomplete'].to_s

      if autocomplete.match?(/one-time-code/i)
        log_two_factor_match(input, 'autocomplete attribute one-time-code')
        return true
      end

      return false if name.empty?

      name_patterns = [
        /otp/i,
        /two[_-]?factor/i,
        /one[_-]?time/i,
        /(confirmation|verification|auth(?:entication)?)_?code/i,
        /email_confirmation_code/i,
        /(confirmation|verification|auth(?:entication)?|email)[_-]?token/i
      ]

      name_patterns.any? do |pattern|
        next false unless name.match?(pattern)

        log_two_factor_match(input, "name pattern #{pattern.inspect}")
        true
      end
    end

    def follow_redirect(response, base_uri)
      location = response['location']
      unless location
        log('Redirect response missing location header; falling back to session verification')
        verify_login!
        return
      end

      target = URI.join(base_uri, location)
      log("Following redirect to #{target}")
      html = @client.get(target)
      doc = Nokogiri::HTML(html)

      if (two_factor_form = locate_two_factor_form(doc))
        log('Fantia requested a two-factor authentication code via email')
        complete_two_factor_challenge(two_factor_form, target)
      else
        log("No two-factor form detected after redirect to #{target}")
        verify_login!
      end
    end

    def obtain_otp
      unless @otp.to_s.strip.empty?
        log('Using pre-supplied two-factor authentication code')
        return @otp
      end

      unless @otp_provider
        log('No OTP provider configured; cannot obtain two-factor authentication code automatically')
        return
      end

      log('Waiting for Fantia two-factor authentication code input')
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

    def verify_login!
      log('Verifying Fantia login session')
      html = @client.get(ACCOUNT_HOME_URI)
      doc = Nokogiri::HTML(html)

      if locate_login_form(doc)
        log('Fantia login verification failed: login form still present on account page')
        raise 'Fantia login verification failed. Please confirm your credentials or two-factor authentication code.'
      end

      log('Fantia login verification succeeded')
      @authenticated = true
    end

    def log(message)
      @logger&.call(message)
    end

    def log_two_factor_match(input, reason)
      name = input['name'] || '(unnamed)'
      type = input['type'] || 'text'
      log("Detected possible two-factor input #{name.inspect} (type: #{type}) via #{reason}")
    end
  end
end
