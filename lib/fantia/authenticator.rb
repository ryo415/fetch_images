# frozen_string_literal: true

require 'nokogiri'
require 'set'
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
      log("Received Fantia sign-in page (#{html&.bytesize || 0} bytes)")
      doc = Nokogiri::HTML(html)
      log_sign_in_forms(doc)
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

      detection = detect_two_factor_challenge(response.body, login_uri)
      if detection[:form]
        log('Fantia requested a two-factor authentication code via email')
        complete_two_factor_challenge(detection[:form], detection[:page_uri])
        return true if @authenticated

        message = extract_two_factor_error(detection[:doc])
        raise "Two-factor authentication failed: #{message}"
      end

      doc = detection[:doc]
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

      detection = detect_two_factor_challenge(response.body, target_uri)
      if detection[:form]
        message = extract_two_factor_error(detection[:doc])
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

      log("Prepared two-factor payload: #{masked_params(payload)}")
      payload
    end

    def two_factor_input?(input)
      type = input['type']&.downcase
      name = input['name'].to_s
      autocomplete = input['autocomplete'].to_s

      if autocomplete.match?(/one-time-code/i)
        log_two_factor_match(input, 'autocomplete attribute one-time-code')
        return true
      end

      return false if %w[submit button image].include?(type)

      candidate_strings = [name, input['id'], input['data-controller'], input['data-action'], input['class']].compact
      candidate_strings.reject!(&:empty?)

      candidate_strings.each do |candidate|
        next unless two_factor_identifier?(candidate)

        log_two_factor_match(input, "attribute match #{candidate}")
        return true
      end

      false
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
      detection = detect_two_factor_challenge(html, target)

      if detection[:form]
        log('Fantia requested a two-factor authentication code via email')
        complete_two_factor_challenge(detection[:form], detection[:page_uri])
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
      log('Received two-factor authentication code from provider')
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
      log("Fetched Fantia account home (#{html&.bytesize || 0} bytes)")
      doc = Nokogiri::HTML(html)
      log("Account page contains #{doc.css('form').size} form(s)")

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

    def detect_two_factor_challenge(html, current_page_uri, visited_frames = Set.new, depth = 0)
      log("Scanning #{current_page_uri} for two-factor challenges (depth #{depth})")
      doc = Nokogiri::HTML(html)
      log("Page contains #{doc.css('form').size} form(s) and #{doc.css('turbo-frame, iframe').size} frame(s)")
      form = locate_two_factor_form(doc)
      return { form: form, doc: doc, page_uri: current_page_uri } if form

      return { form: nil, doc: doc, page_uri: current_page_uri } if depth >= 5

      frame_candidates = doc.css('turbo-frame[src], iframe[src]')
      frame_candidates.each do |frame|
        next unless possible_two_factor_frame?(frame, current_page_uri)

        src = frame['src'].to_s.strip
        next if src.empty?

        frame_uri = URI.join(current_page_uri, src)
        key = frame_uri.to_s
        next if visited_frames.include?(key)

        visited_frames.add(key)
        log("Fetching potential two-factor frame #{frame_uri}")
        frame_html = @client.get(frame_uri)
        detection = detect_two_factor_challenge(frame_html, frame_uri, visited_frames, depth + 1)
        return detection if detection[:form]
      end

      { form: nil, doc: doc, page_uri: current_page_uri }
    end

    def locate_two_factor_form(doc)
      doc.css('form').each do |candidate|
        description = describe_form(candidate)
        log("Inspecting form #{description} for two-factor inputs")
        if candidate.css('input').any? { |input| two_factor_input?(input) }
          log("Identified two-factor form: #{description}")
          return candidate
        end
      end
      nil
    end

    def possible_two_factor_frame?(frame, current_page_uri)
      src = frame['src'].to_s
      attributes = [frame['id'], src, frame['name'], frame['class'], frame['data-controller']].compact.join(' ')
      return true if attributes.match?(/two[_-]?factor|otp|one[_-]?time|email[_-]?confirmation|verification/i)
      return true if src.match?(/sessions|two[_-]?factor|otp|code|token|verification/i)

      if current_page_uri.host == SIGN_IN_URI.host && current_page_uri.path.start_with?('/sessions')
        # Fantia embeds the OTP form inside unnamed turbo frames on the sign-in page.
        # When we are still on the sessions area we aggressively inspect every frame.
        return true
      end

      frame.text.match?(/二段階認証|ワンタイム|認証コード|確認コード/) # Japanese hints
    end

    def two_factor_identifier?(text)
      normalized = text.dup
      normalized.tr!('-', '_')
      normalized.downcase!

      return false if normalized.empty?
      return false if normalized.include?('authenticity_token')

      patterns = [
        /\botp\b/,
        /two_?factor/,
        /one_?time/,
        /email_?code/,
        /(confirmation|verification)[_\-]?(code|token|number)/,
        /email_?confirmation/,
        /security_?code/,
        /login_?code/,
        /認証コード/,
        /確認コード/
      ]

      patterns.any? { |pattern| normalized.match?(pattern) }
    end

    def log_sign_in_forms(doc)
      forms = doc.css('form[action]')
      return log('Fantia sign-in page does not expose any POST forms') if forms.empty?

      summary = forms.map { |form| describe_form(form) }.join('; ')
      log("Fantia sign-in page exposes #{forms.size} form(s): #{summary}")
    end

    def describe_form(form)
      action = form['action'].to_s.strip
      action = '(self)' if action.empty?
      method = form['method'].to_s.strip.upcase
      method = 'GET' if method.empty?
      identifiers = []
      identifiers << "id=#{form['id']}" if form['id']
      identifiers << "class=#{form['class']}" if form['class']
      "action=#{action} method=#{method} #{identifiers.join(' ')}".strip
    end

    def masked_params(params)
      params.map do |key, value|
        masked_value = if key.to_s.match?(/password|otp|token|code/i)
                         '[hidden]'
                       elsif value.nil? || value.to_s.empty?
                         '(empty)'
                       else
                         value.to_s[0, 40]
                       end
        "#{key}=#{masked_value}"
      end.join(', ')
    end
  end
end
