class LdapFilterParser
  attr_reader :result

  WILDCARD_MARK = "[:wildcard:]"
  ITEM_PARSER = /([^~=><]+)(~=|>=|<=|=)(.+)/

  def initialize(opts = {})
    @logger = opts[:logger]
    @result = nil
  end

  def parse(filter)
    @result = nil
    hash = {}
    log("CHECK:#{filter[0]}")

    case filter[0]
    when "("
      subs = subfilters(filter)
      hash[:filter] = parse(subs[0])
    when "&", "|"
      hash[:operator] = filter[0]
      hash[:filterlist] = subfilters(filter[1..]).collect do |node|
        parse(node)
      end
    when "!"
      subs = subfilters(filter)
      if subs.size != 1
        raise LdapFilterError, "not operator has more than one filter"
      end

      hash[:operator] = filter[0]
      hash[:filter] = parse(subfilters(filter[1..])[0])
    else
      hash[:item] = parse_item(subfilters(filter))
    end

    @result = hash
  end

  private

  def subfilters(filter)
    log("subfilters: #{filter}")
    ary = []
    depth = 0
    start_pos = 0

    (start_pos..filter.size).each do |i|
      case filter[i]
      when "("
        start_pos = i + 1 if depth.zero?
        depth += 1
      when ")"
        depth -= 1
        if depth.zero?
          sub = filter[start_pos..i - 1]
          log("node: #{filter[start_pos..]} -> #{sub}")
          ary << sub
        end
      end
    end

    raise LdapFilterError, "parenthesis mismatch" unless depth.zero?

    ary.empty? ? filter : ary
  end

  def unescape(str)
    return str if str == "*"

    str.gsub("*", WILDCARD_MARK).gsub(/\\([0-9a-fA-F]{2})/) { Regexp.last_match(1).to_i(16).chr }
  end

  def parse_item(item)
    m = ITEM_PARSER.match(item)
    raise LdapFilterError, "error in item syntax" if m.nil?

    hash = {
      attr: m[1],
      filtertype: m[2],
      value: unescape(m[3])
    }
    if hash[:value].include?(WILDCARD_MARK)
      hash[:regex] = Regexp.new(hash[:value].gsub("*", "\\*").gsub(WILDCARD_MARK, ".*"))
    end
    hash
  end

  def log(mesg)
    return if @logger.nil?

    @logger.info(mesg)
  end
end
