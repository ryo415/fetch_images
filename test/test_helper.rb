# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../lib/fetch_images"

module ClientFixtures
  def client_with_payload(klass, payload, **options)
    klass.new(**options).tap do |client|
      client.define_singleton_method(:fetch_post_payload) { |_| ["42", payload] }
      client.define_singleton_method(:http_get) { |*_, **_| raise "unexpected HTTP" }
    end
  end
end
