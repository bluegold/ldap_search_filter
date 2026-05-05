# frozen_string_literal: true

class LTSV
  class << self
    def parse_line(line, options = {})
      symbolize_keys = options.fetch(:symbolize_keys, true)
      line.split("\t").each_with_object({}) do |entry, result|
        key, value = entry.split(":", 2)
        next unless key

        key = key.to_sym if symbolize_keys
        result[key] = normalize_value(unescape(value))
      end
    end

    def parse(string, options = {})
      parse_line(string.chomp, options)
    end

    def unescape(value)
      return nil if !value || value.empty?

      value.gsub(/\\([rnt\\])/) do
        case Regexp.last_match(1)
        when "r" then "\r"
        when "n" then "\n"
        when "t" then "\t"
        when "\\" then "\\"
        end
      end
    end

    def normalize_value(value)
      value.nil? || value.empty? ? nil : value
    end
  end
end
