class LTSV
  class << self
    def parse_line(line, options = {})
      symbolize_keys = options.delete(:symbolize_keys)
      symbolize_keys = true if symbolize_keys.nil?

      line.split("\t").inject({}) do |h, i|
        key, value = i.split(":", 2)
        next h unless key

        key = key.to_sym if symbolize_keys
        unescape!(value)
        h[key] = case value
                 when nil then nil
                 when "" then nil
                 else value
                 end
        h
      end
    end

    def parse(string, options = {})
      string.chomp.split($/).map { |l| parse_line(l, options) }.reduce({}, :merge)
    end

    def unescape!(string)
      return nil if !string || string == ""

      string.gsub!(/\\([a-z\\])/) do
        case Regexp.last_match(1)
        when "r"
          "\r"
        when "n"
          "\n"
        when "t"
          "\t"
        when "\\"
          "\\"
        else
          Regexp.last_match(0)
        end
      end
    end
  end
end
