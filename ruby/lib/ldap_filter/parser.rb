# frozen_string_literal: true

module LdapFilter
  class Parser
  attr_reader :result

  HEX_DIGITS = /\A[0-9a-fA-F]{2}\z/
  OPERATORS = %w[~= >= <= =].freeze
  KEY_TYPES = %i[string symbol].freeze

  def initialize(opts = {})
    @logger = opts[:logger]
    @keytype = opts.fetch(:keytype, :string)
    raise ArgumentError, "keytype must be :string or :symbol" unless KEY_TYPES.include?(@keytype)

    @result = nil
  end

  def parse(filter)
    raise Error, "empty filter" if filter.empty?

    @chars = filter.each_char.to_a
    @position = 0
    @result = parse_filter

    raise Error, "unexpected trailing input" unless eof?

    @result
  ensure
    @chars = nil
    @position = nil
  end

  private

  def parse_filter
    expect("(")
    node = parse_filter_content
    expect(")")
    node
  end

  def parse_filter_content
    log("CHECK:#{peek}")

    case peek
    when "&"
      advance
      And.new(parse_filter_list)
    when "|"
      advance
      Or.new(parse_filter_list)
    when "!"
      advance
      raise Error, "not operator requires one filter" if peek == ")" || eof?

      child = parse_filter
      raise Error, "not operator has more than one filter" unless peek == ")"

      Not.new(child)
    when ")", nil
      raise Error, "empty filter"
    else
      parse_item
    end
  end

  def parse_filter_list
    nodes = []
    nodes << parse_filter until peek == ")"
    raise Error, "operator requires at least one filter" if nodes.empty?

    nodes
  end

  def parse_item
    attr = read_attribute
    operator = read_operator
    raw_value = read_value

    attr = attr.to_sym if @keytype == :symbol
    value, regex = decode_value(raw_value)

    Item.new(
      attr: attr,
      filtertype: operator,
      value: value,
      regex: regex
    )
  end

  def read_attribute
    start = @position
    advance while !eof? && !operator_start?(peek) && peek != "(" && peek != ")"
    attr = @chars[start...@position].join
    raise Error, "error in item syntax" if attr.empty? || peek == "("

    attr
  end

  def read_operator
    operator = peek
    raise Error, "error in item syntax" unless operator_start?(operator)

    if operator == "="
      advance
      return "="
    end

    advance
    raise Error, "error in item syntax" unless peek == "="

    advance
    candidate = "#{operator}="
    raise Error, "unsupported operator: #{candidate}" unless OPERATORS.include?(candidate)

    candidate
  end

  def read_value
    start = @position
    advance while !eof? && peek != ")"
    raise Error, "parenthesis mismatch" if eof?
    raise Error, "error in item syntax" if @chars[start...@position].include?("(")

    @chars[start...@position].join
  end

  def decode_value(raw)
    bytes = String.new(capacity: raw.bytesize, encoding: Encoding::BINARY)
    segments = []
    segment = String.new(encoding: Encoding::BINARY)
    has_wildcard = false
    i = 0

    while i < raw.length
      char = raw[i]
      case char
      when "\\"
        hex = raw[i + 1, 2]
        raise Error, "invalid escape sequence" unless hex&.match?(HEX_DIGITS)

        byte = hex.to_i(16)
        bytes << byte
        segment << byte
        i += 3
      when "*"
        has_wildcard = true
        bytes << "*"
        segments << decode_utf8(segment)
        segment = String.new(encoding: Encoding::BINARY)
        i += 1
      else
        encoded = char.encode(Encoding::UTF_8)
        bytes << encoded
        segment << encoded
        i += 1
      end
    end

    value = decode_utf8(bytes)
    regex = if has_wildcard && raw != "*"
      segments << decode_utf8(segment)
      pattern = segments.map { |part| Regexp.escape(part) }.join(".*")
      Regexp.new("\\A#{pattern}\\z")
    end

    [value, regex]
  end

  def decode_utf8(bytes)
    value = bytes.dup.force_encoding(Encoding::UTF_8)
    raise EncodingError unless value.valid_encoding?

    value
  rescue EncodingError
    raise Error, "invalid UTF-8 escape sequence"
  end

  def operator_start?(char)
    %w[= ~ > <].include?(char)
  end

  def expect(char)
    raise Error, "parenthesis mismatch" unless peek == char

    advance
  end

  def peek
    return nil if eof?

    @chars[@position]
  end

  def advance
    @position += 1
  end

  def eof?
    @position >= @chars.length
  end

  def log(message)
    return if @logger.nil?

    @logger.info(message)
  end
  end
end
