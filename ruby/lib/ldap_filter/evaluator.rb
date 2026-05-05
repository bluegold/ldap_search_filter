require "did_you_mean/levenshtein"

class LdapFilterEvaluator
  attr_reader :rule

  OPERATOR_MAP = {
    "&" => :do_operator_and,
    "|" => :do_operator_or,
    "!" => :do_operator_not,
    "=" => :do_item_equal,
    "~=" => :do_item_approx,
    ">=" => :do_item_greater,
    "<=" => :do_item_less
  }.freeze

  def initialize(filter, opts = {})
    case filter
    when String
      parser = LdapFilterParser.new(opts)
      parser.parse(filter)
      @rule = parser.result
    when LdapFilterParser
      @rule = filter.result
    end
    @logger = opts[:logger]
    @symbolkey = (opts[:keytype] == :symbol)
  end

  def evaluate(attrs = {}, rule = nil)
    log(attrs, :yaml)
    rule ||= @rule[:filter]

    [:item, :operator].each do |key|
      next unless rule.has_key?(key)

      method = "do_#{key}"
      log("method: #{method}")
      log(rule, :yaml)

      result = send(method, rule, attrs) if respond_to?(method, true)
      log("result: #{result}")
      return result
    end
  end

  private

  def do_item(rule, attrs)
    method = OPERATOR_MAP[rule[:item][:filtertype]]
    rule[:item][:attr] = rule[:item][:attr].to_sym if @symbolkey

    send(method, rule[:item], attrs) if respond_to?(method, true)
  end

  def do_item_equal(rule, attrs)
    log("do_item_equal: #{rule[:attr]}(#{attrs[rule[:attr]]}) == #{rule[:value]}")
    if rule[:value] == "*"
      attrs.has_key?(rule[:attr])
    elsif rule.has_key?(:regex)
      log("do_item_equal: using regex:#{rule[:regex].inspect} result:#{rule[:regex] =~ attrs[rule[:attr]]}")
      !!(rule[:regex] =~ attrs[rule[:attr]])
    else
      rule[:value] == attrs[rule[:attr]]
    end
  end

  def do_item_approx(rule, attrs)
    log("do_item_approx: #{rule[:attr]}(#{attrs[rule[:attr]]}) ~= #{rule[:value]}")
    distance = DidYouMean::Levenshtein.distance(rule[:value], attrs[rule[:attr]])
    log("do_item_approx: levenshtein distance:#{distance}")
    distance < 3
  end

  def do_item_greater(rule, attrs)
    log("do_item_greater: #{rule[:attr]}(#{attrs[rule[:attr]]}) >= #{rule[:value]}")
    attrs[rule[:attr]] >= rule[:value]
  end

  def do_item_less(rule, attrs)
    log("do_item_less: #{rule[:attr]}(#{attrs[rule[:attr]]}) <= #{rule[:value]}")
    attrs[rule[:attr]] <= rule[:value]
  end

  def do_operator(rule, attrs)
    method = OPERATOR_MAP[rule[:operator]]
    send(method, rule, attrs) if respond_to?(method, true)
  end

  def do_operator_and(rule, attrs)
    results = rule[:filterlist].collect do |subrule|
      evaluate(attrs, subrule)
    end

    log(results, :inspect, :do_operator_and)
    !results.include?(false)
  end

  def do_operator_or(rule, attrs)
    rule[:filterlist].each do |subrule|
      result = evaluate(attrs, subrule)
      if result
        log(rule, :inspect, :do_operator_or)
        return true
      end
    end
    log("do_operator_or: result:false")
    false
  end

  def do_operator_not(rule, attrs)
    log(rule, :inspect, :do_operator_not)
    result = evaluate(attrs, rule[:filter])
    !result
  end

  def log(mesg, type = :normal, method = nil)
    return if @logger.nil?

    ary = []
    ary << "method:#{method}" unless method.nil?
    case type
    when :normal
      ary << mesg
    when :yaml
      ary << mesg.to_yaml
    when :inspect
      ary << mesg.inspect
    end
    @logger.info ary.join("\n")
  end
end
