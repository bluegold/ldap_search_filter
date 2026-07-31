# frozen_string_literal: true

require "did_you_mean/levenshtein"

module LdapFilter
  class Node
    def evaluate(_attrs)
      raise NotImplementedError, "#{self.class} must implement #evaluate"
    end
  end

  class Item < Node
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
        if @regex
          return false unless actual.is_a?(String)

          return @regex.match?(actual)
        end

        @value == actual
      when "~="
        return false unless actual.is_a?(String)

        DidYouMean::Levenshtein.distance(@value, actual) < 3
      when ">="
        return false unless actual.is_a?(String)

        actual >= @value
      when "<="
        return false unless actual.is_a?(String)

        actual <= @value
      else
        false
      end
    end
  end

  class And < Node
    attr_reader :children

    def initialize(children)
      @children = children.freeze
      freeze
    end

    def evaluate(attrs)
      @children.all? { |child| child.evaluate(attrs) }
    end
  end

  class Or < Node
    attr_reader :children

    def initialize(children)
      @children = children.freeze
      freeze
    end

    def evaluate(attrs)
      @children.any? { |child| child.evaluate(attrs) }
    end
  end

  class Not < Node
    attr_reader :child

    def initialize(child)
      @child = child
      freeze
    end

    def evaluate(attrs)
      !@child.evaluate(attrs)
    end
  end
end
