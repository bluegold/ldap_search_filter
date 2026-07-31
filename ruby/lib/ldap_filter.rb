require_relative "ldap_filter/version"
require_relative "ldap_filter/error"
require_relative "ldap_filter/node"
require_relative "ldap_filter/parser"
require_relative "ldap_filter/evaluator"
require_relative "ldap_filter/ltsv"

module LdapFilter
  module_function

  def parse(filter, keytype: :string, logger: nil)
    Parser.new(keytype: keytype, logger: logger).parse(filter)
  end

  def evaluate(filter, attrs = nil, keytype: :string, logger: nil, **keyword_attrs)
    attrs = (attrs || {}).merge(keyword_attrs)
    Evaluator.new(filter, keytype: keytype, logger: logger).evaluate(attrs)
  end
end
