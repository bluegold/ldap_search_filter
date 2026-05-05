# frozen_string_literal: true

class LdapFilterParser
  attr_reader :result

  ITEM_PARSER = /\A([^~=><]+)(~=|>=|<=|=)(.+)\z/

  def initialize(opts = {})
    @logger = opts[:logger]
    @symbolkey = (opts[:keytype] == :symbol)
    @result = nil
  end

  def parse(filter)
    @result = parse_node(filter)
  end

  private

  def parse_node(filter)
    log("CHECK:#{filter[0]}")

    case filter[0]
    when "("
      nodes = subfilters(filter)
      parse_node(nodes[0])
    when "&"
      LdapFilterAnd.new(subfilters(filter[1..]).map { |node| parse_node(node) })
    when "|"
      LdapFilterOr.new(subfilters(filter[1..]).map { |node| parse_node(node) })
    when "!"
      nodes = subfilters(filter)
      raise LdapFilterError, "not operator has more than one filter" unless nodes.size == 1

      LdapFilterNot.new(parse_node(nodes[0]))
    else
      parse_item(filter)
    end
  end

  def subfilters(filter)
    log("subfilters: #{filter}")
    ary = []
    depth = 0
    start_pos = 0

    filter.each_char.with_index do |char, i|
      case char
      when "("
        start_pos = i + 1 if depth.zero?
        depth += 1
      when ")"
        depth -= 1
        if depth.zero?
          sub = filter[start_pos...i]
          log("node: #{filter[start_pos..]} -> #{sub}")
          ary << sub
        end
      end
    end

    raise LdapFilterError, "parenthesis mismatch" unless depth.zero?

    ary.empty? ? [filter] : ary
  end

  def unescape(text)
    return text if text == "*"

    value = String.new(capacity: text.bytesize)
    i = 0
    while i < text.length
      char = text[i]
      if char == "\\" && i + 2 < text.length
        hex = text[i + 1, 2]
        if hex.match?(/\A[0-9a-fA-F]{2}\z/)
          value << hex.to_i(16).chr
          i += 3
          next
        end
      end

      value << char
      i += 1
    end

    value
  end

  def parse_item(item)
    match = ITEM_PARSER.match(item)
    raise LdapFilterError, "error in item syntax" if match.nil?

    attr = match[1]
    attr = attr.to_sym if @symbolkey
    value = unescape(match[3])

    regex = if value != "*" && value.include?("*")
      Regexp.new(Regexp.escape(value).gsub("\\*", ".*"))
    end

    LdapFilterItem.new(
      attr: attr,
      filtertype: match[2],
      value: value,
      regex: regex
    )
  end

  def log(message)
    return if @logger.nil?

    @logger.info(message)
  end
end
