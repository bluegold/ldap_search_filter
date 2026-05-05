# frozen_string_literal: true

require "did_you_mean/levenshtein"

class LdapFilterNode
  def evaluate(_attrs)
    raise NotImplementedError, "#{self.class} must implement #evaluate"
  end
end

class LdapFilterItem < LdapFilterNode
  attr_reader :attr, :filtertype, :value, :regex

  def initialize(attr:, filtertype:, value:, regex: nil)
    @attr = attr
    @filtertype = filtertype
    @value = value
    @regex = regex
    freeze
  end

  def evaluate(attrs)
    actual = attrs[@attr]

    case @filtertype
    when "="
      return attrs.key?(@attr) if @value == "*"
      return !!@regex&.match?(actual) if @regex && actual

      @value == actual
    when "~="
      actual && DidYouMean::Levenshtein.distance(@value, actual) < 3
    when ">="
      actual && actual >= @value
    when "<="
      actual && actual <= @value
    else
      false
    end
  end
end

class LdapFilterAnd < LdapFilterNode
  attr_reader :children

  def initialize(children)
    @children = children.freeze
    freeze
  end

  def evaluate(attrs)
    @children.all? { |child| child.evaluate(attrs) }
  end
end

class LdapFilterOr < LdapFilterNode
  attr_reader :children

  def initialize(children)
    @children = children.freeze
    freeze
  end

  def evaluate(attrs)
    @children.any? { |child| child.evaluate(attrs) }
  end
end

class LdapFilterNot < LdapFilterNode
  attr_reader :child

  def initialize(child)
    @child = child
    freeze
  end

  def evaluate(attrs)
    !@child.evaluate(attrs)
  end
end
