# frozen_string_literal: true

require "yaml"

class LdapFilterEvaluator
  attr_reader :rule

  def initialize(filter, keytype: :string, logger: nil)
    @logger = logger

    @rule =
      case filter
      when String
        LdapFilterParser.new(keytype: keytype, logger: logger).parse(filter)
      when LdapFilterNode
        filter
      else
        raise ArgumentError, "filter must be a String or LdapFilterNode"
      end
  end

  def evaluate(attrs = nil, **keyword_attrs)
    attrs = (attrs || {}).merge(keyword_attrs)
    log(attrs)

    result = !!@rule.evaluate(attrs)
    log("result: #{result}")
    result
  end

  private

  def log(message)
    return if @logger.nil?

    @logger.info(message.is_a?(String) ? message : message.to_yaml)
  end
end
