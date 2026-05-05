# frozen_string_literal: true

class LdapFilterEvaluator
  attr_reader :rule

  def initialize(filter, opts = {})
    @logger = opts[:logger]

    @rule =
      case filter
      when String
        parser = LdapFilterParser.new(opts)
        parser.parse(filter)
        parser.result
      when LdapFilterNode
        filter
      else
        filter&.result
      end
  end

  def evaluate(attrs = {}, rule = nil)
    log(attrs, :yaml)
    node = rule || @rule

    result = node.evaluate(attrs)
    log("result: #{result}")
    result
  end

  private

  def log(message, type = :normal, method = nil)
    return if @logger.nil?

    ary = []
    ary << "method:#{method}" unless method.nil?
    case type
    when :normal
      ary << message
    when :yaml
      ary << message.to_yaml
    when :inspect
      ary << message.inspect
    end
    @logger.info ary.join("\n")
  end
end
