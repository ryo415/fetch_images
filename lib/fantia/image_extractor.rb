# frozen_string_literal: true

require 'nokogiri'
require 'uri'

module Fantia
  class ImageExtractor
    IMAGE_ATTRIBUTES = %w[data-src data-original data-url data-image data-srcset data-original-src srcset src].freeze
    IMAGE_EXTENSION_REGEX = /\A\.(png|jpe?g|gif|webp|bmp|svg)\z/i.freeze
    SCRIPT_IMAGE_REGEX = %r{(?:(?:https?:)?//|/)[^"'\s)]+?\.(?:png|jpe?g|gif|webp|bmp|svg)(?:\?[^"'\s)]*)?}i.freeze

    def initialize(logger: nil)
      @logger = logger
    end

    def extract(doc, base_uri)
      urls = []

      doc.css('img').each do |img|
        candidate = select_best_image_source(img)
        next unless candidate

        begin
          urls << URI.join(base_uri, candidate)
        rescue URI::Error
          log("Skipping invalid image URL: #{candidate}")
        end
      end

      doc.css('a[data-download], a[download]').each do |link|
        href = link['href']
        next unless href

        begin
          absolute = URI.join(base_uri, href)
          urls << absolute if image_extension?(absolute)
        rescue URI::Error
          log("Skipping invalid download URL: #{href}")
        end
      end

      extract_from_scripts(doc, base_uri, urls)

      urls.uniq
    end

    private

    def select_best_image_source(img)
      IMAGE_ATTRIBUTES.each do |attr|
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
      File.extname(uri.path).match?(IMAGE_EXTENSION_REGEX)
    end

    def extract_from_scripts(doc, base_uri, urls)
      doc.css('script').each do |script|
        content = script.text
        next if content.to_s.empty?

        normalized = content.gsub('\\/', '/')

        normalized.scan(SCRIPT_IMAGE_REGEX) do |match|
          candidate = match.is_a?(Array) ? match.compact.first : match
          next unless candidate

          begin
            absolute = URI.join(base_uri, candidate)
            urls << absolute
          rescue URI::Error
            log("Skipping invalid script image URL: #{candidate}")
          end
        end
      end
    end

    def log(message)
      @logger&.call(message)
    end
  end
end
