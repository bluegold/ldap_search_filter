class LdapFilterError < StandardError; end

class LdapFilterParser
  attr_reader :result

  def initialize(opts = {})
    @logger = opts[:logger]
    @result = nil
  end

  def parse(filter)
    @result = nil
    hash = {}
    log("CHECK:#{filter[0]}")
    case  filter[0]
    when  '('
      subs = subfilters(filter)
      hash[:filter] = parse(subs[0])
    when  '&', '|'
      hash[:operator] = filter[0]
      hash[:filterlist] = subfilters(filter[1..]).collect do |node|
        parse(node)
      end
    when  '!'
      subs = subfilters(filter)
      if subs.size != 1
        raise LdapFilterError.new("not operator has more than one filter")
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
      case  filter[i]
      when  '('
        if depth == 0
          start_pos = i+1
        end
        depth += 1
      when ')'
        depth -= 1
        if depth.zero?
          sub = filter[start_pos..i-1] # () の内部のみ
          log("node: #{filter[start_pos..]} -> #{sub}")
          ary << sub
        end
      end
    end

    raise LdapFilterError.new("parenthesis mismatch") unless depth.zero?

    if ary.empty?
      return filter # item (RFC2544)
    else
      return ary
    end
  end

  WILDCARD_MARK = '[:wildcard:]'

  def unescape(str)
    return str if str == '*'
    return str.gsub('*', WILDCARD_MARK)
              .gsub(/\\([0-9a-fA-F]{2})/) { $1.to_i(16).chr }
  end

  ITEM_PARSER = /([^~=><]+)(~=|>=|<=|=)(.+)/

  def parse_item(item)
    m = ITEM_PARSER.match(item)
    raise LdapFilterError.new("error in item syntax") if m.nil?

    hash = {
      attr: m[1],
      filtertype: m[2],
      value: unescape(m[3])
    }
    if hash[:value].include?(WILDCARD_MARK)
      hash[:regex] = Regexp.new(hash[:value].gsub('*', '\*').gsub(WILDCARD_MARK, '.*'))
    end
    return hash
  end

  def log(mesg)
    return if @logger.nil?

    @logger.info(mesg)
  end
end

#require 'did_you_mean/levenshtein'

class LdapFilterError < StandardError; end

class LdapFilterEvaluator
  attr_reader :rule

  def initialize(filter, opts = {})
    case  filter
    when  String
      parser = LdapFilterParser.new(opts)
      parser.parse(filter)
      @rule = parser.result
    when  LdapFilterParser
      @rule = filter.result
    end
    @logger = opts[:logger]
    @symbolkey = (opts[:keytype] == :symbol)
  end

  def evaluate(attrs = {}, rule = nil)
    log(attrs, :yaml)
    rule ||= @rule[:filter]

    [:item, :operator].each do |key|
      if rule.has_key?(key)
        method = "do_#{key}"
        log("method: #{method}")
        log(rule, :yaml)

        result = send(method, rule, attrs) if respond_to?(method, true)
        log("result: #{result}")
        return result
      end
    end
  end

private

  OPERATOR_MAP = {
    '&' => :do_operator_and,
    '|' => :do_operator_or,
    '!' => :do_operator_not,
    '=' => :do_item_equal,
    '~=' => :do_item_approx,
    '>=' => :do_item_greater,
    '<=' => :do_item_less,
  }.freeze

  def do_item(rule, attrs)
    method = OPERATOR_MAP[rule[:item][:filtertype]]
    rule[:item][:attr] = rule[:item][:attr].to_sym if @symbolkey

    return send(method, rule[:item], attrs) if respond_to?(method, true)
  end

  def do_item_equal(rule, attrs)
    log("do_item_equal: #{rule[:attr]}(#{attrs[rule[:attr]]}) == #{rule[:value]}")
    if rule[:value] == '*'
      return attrs.has_key?(rule[:attr])
    elsif rule.has_key?(:regex)
      log("do_item_equal: using regex:#{rule[:regex].inspect} result:#{rule[:regex] =~ attrs[rule[:attr]]}")
      return !!(rule[:regex] =~ attrs[rule[:attr]])
    else
      return rule[:value] == attrs[rule[:attr]]
    end
  end

  def do_item_approx(rule, attrs)
    log("do_item_approx: #{rule[:attr]}(#{attrs[rule[:attr]]}) ~= #{rule[:value]}")
    distance = DidYouMean::Levenshtein.distance(rule[:value], attrs[rule[:attr]])
    log("do_item_approx: levenshtein distance:#{distance}")
    return distance < 3
  end

  def do_item_greater(rule, attrs)
    log("do_item_greater: #{rule[:attr]}(#{attrs[rule[:attr]]}) >= #{rule[:value]}")
    return attrs[rule[:attr]] >= rule[:value]
  end

  def do_item_less(rule, attrs)
    log("do_item_less: #{rule[:attr]}(#{attrs[rule[:attr]]}) <= #{rule[:value]}")
    return attrs[rule[:attr]] <= rule[:value] 
  end

  def do_operator(rule, attrs)
    method = OPERATOR_MAP[rule[:operator]]
    return send(method, rule, attrs) if respond_to?(method, true)
  end

  def do_operator_and(rule, attrs)
    results = rule[:filterlist].collect do |rule|
      evaluate(attrs, rule)
    end

    log(results, :inspect, :do_operator_and)
    return !results.include?(false)
  end

  def do_operator_or(rule, attrs)
    rule[:filterlist].each do |rule|
      result = evaluate(attrs, rule)
      if result
        log(rule, :inspect, :do_operator_or)
        return true
      end
    end
    log("do_operator_or: result:false")
    return false
  end

  def do_operator_not(rule, attrs)
    log(rule, :inspect, :do_operator_not)
    result = evaluate(attrs, rule[:filter])
    return !result
  end

  def log(mesg, type = :normal, method = nil)
    return if @logger.nil?

    ary = []
    ary << "method:#{method}" unless method.nil?
    case  type
    when  :normal
      ary << mesg
    when  :yaml
      ary << mesg.to_yaml
    when  :inspect
      ary << mesg.inspect
    end
    @logger.info ary.join("\n")
  end
end

if $0 == __FILE__ || true
#  $LOAD_PATH << '.'
#  require 'ldap_filter_parser'
#  require 'yaml'
#  require 'logger'
#  require 'optparse'
#  require 'csv'
#  require 'ltsv'

#  $args = ARGV.getopts("v", "ltsv", "e:", "debug")
  opts = {}
  opts[:keytype] = :symbol
#  opts[:logger] = Logger.new($stderr)
#  if $args["debug"]
#    opts[:logger] = Logger.new($stderr)
#  end

class LTSV
  class << self
    def parse_line(line, options={})#:nodoc:
      symbolize_keys = options.delete(:symbolize_keys)
      symbolize_keys = true if symbolize_keys.nil?

      line.split("\t").inject({}) do |h, i|
        (key, value) = i.split(':', 2)
        next unless key
        key = key.to_sym if symbolize_keys
        unescape!(value)
        h[key] = case value
             when nil then nil
             when '' then nil
             else value
             end
        h
      end
    end

    def parse(string, options = {})#:nodoc:
      string.chomp.split($/).map{|l|parse_line l, options}.reduce({}, :merge)
    end

    def unescape!(string)#:nodoc:
      return nil if !string || string == ''

      string.gsub!(/\\([a-z\\])/) do |m|
        case $1
        when 'r'
          "\r"
        when 'n'
          "\n"
        when 't'
          "\t"
        when '\\'
          '\\'
        else
          m
        end
      end
    end

  end
end

  log_parser = LTSV
#  log_parser = CSV
#  if $args["ltsv"]
#    log_parser = LTSV
#  end

#  evaluator = LdapFilterEvaluator.new($args["e"], opts)
  evaluator = LdapFilterEvaluator.new(ARGV[0], opts)
#  if opts[:logger]
#    opts[:logger].info evaluator.rule.to_yaml
#  end

  first_line = true
  headers = nil

  File.open(ARGV[1]) do |f|
    f.each_line do |line|
      attrs = log_parser.parse(line)

#    if log_parser == CSV
#      if first_line
#        headers = attrs[0].collect {|k| k.to_sym}
#        first_line = false
#        next
#      end
#
      # Hash に変換
#      workary = [headers, attrs[0]]
#      attrs = Hash[*workary.transpose.flatten]
#    else
      # LTSV
#      attrs = attrs[0]
#    end

      next unless evaluator.evaluate(attrs)

      puts attrs.inspect
    end
  end

end

